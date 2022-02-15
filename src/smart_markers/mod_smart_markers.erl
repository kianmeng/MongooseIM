%%%----------------------------------------------------------------------------
%%% @copyright (C) 2020, Erlang Solutions Ltd.
%%% @doc
%%%   This module implements storage of the latest chat markers
%%%   sent by the users. This can be used to optimize mod_offline
%%%   functionality, or to implement custom fetching protocol and
%%%   avoid storage of chat markers in MAM.
%%%
%%%   Please be aware of the next implementation details:
%%%
%%%    1) Current implementation is based on user_send_packet hook.
%%%       It doesn't work for s2s connections, but usage of another
%%%       hook (e.g. filter_local_packet) makes implementation harder
%%%       and results in multiple processing of one and the same
%%%       chat marker notification (sent to different users by MUC).
%%%       However that is the only possible way to deal with group
%%%       chat messages sent from the room to the user over s2s.
%%%
%%%       ```
%%%                                            S2S
%%%                                             +
%%%                                             |
%%%                +--------------------+       |
%%%                |                    |       |   filter
%%%                |                    +--------------->
%%%       send     |                    |       |   filter
%%%       +------->+       ROOM         +--------------->
%%%                |                    |       |   filter
%%%                |                    +--------------->
%%%                |                    |       |
%%%                +--------------------+       |
%%%                                             |
%%%                                             +
%%%    '''
%%%
%%%    2) DB backend requires us to provide host information, and
%%%       the host is always the recipient's server in case one2one
%%%       messages, and a master domain of the MUC service in case
%%%       of groupchat.
%%%
%%%    3) It is the client application's responsibility to ensure that
%%%       chat markers move only forward. There is no verification of
%%%       chat markers in this module, it just stores the latest chat
%%%       marker information sent by the user.
%%%
%%%    4) MUC light doesn't have message serialization! So it doesn't
%%%       guarantee one and the same message order for different users.
%%%       This can result in a race condition situation when different
%%%       users track (and mark) different messages as the last in a
%%%       chat history. However, this is a rare situation, and it self
%%%       recovers on the next message in the room. Anyway storing chat
%%%       markers in MAM doesn't fix this problem.
%%%
%%% @end
%%%----------------------------------------------------------------------------
-module(mod_smart_markers).

-include("jlib.hrl").
-include("mod_muc_light.hrl").
-include("mongoose_config_spec.hrl").

-xep([{xep, 333}, {version, "0.3"}]).
-behaviour(gen_mod).

%% gen_mod API
-export([start/2, stop/1, supported_features/0, config_spec/0]).

%% Internal API
-export([get_chat_markers/3]).

%% Hook handlers
-export([process_iq/5, user_send_packet/4, remove_user/3, remove_domain/3,
         forget_room/4, room_new_affiliations/4]).
-ignore_xref([process_iq/5, user_send_packet/4, remove_user/3, remove_domain/3,
              forget_room/4, room_new_affiliations/4]).

%%--------------------------------------------------------------------
%% Type declarations
%%--------------------------------------------------------------------
-type maybe_thread() :: undefined | binary().
-type chat_type() :: one2one | groupchat.

-type chat_marker() :: #{from := jid:jid(),
                         to := jid:jid(),
                         thread := maybe_thread(), % it is not optional!
                         type := mongoose_chat_markers:chat_marker_type(),
                         timestamp := integer(), % microsecond
                         id := binary()}.

-export_type([chat_marker/0]).

%%--------------------------------------------------------------------
%% gen_mod API
%%--------------------------------------------------------------------
-spec start(mongooseim:host_type(), gen_mod:module_opts()) -> any().
start(HostType, Opts) ->
    mod_smart_markers_backend:init(HostType, Opts),
    gen_iq_handler:add_iq_handler_for_domain(
      HostType, ?NS_ESL_SMART_MARKERS, ejabberd_sm,
      fun ?MODULE:process_iq/5, #{}, no_queue),
    ejabberd_hooks:add(hooks(HostType)).

-spec stop(mongooseim:host_type()) -> ok.
stop(HostType) ->
    gen_iq_handler:remove_iq_handler_for_domain(HostType, ?NS_ESL_SMART_MARKERS, ejabberd_sm),
    ejabberd_hooks:delete(hooks(HostType)).

-spec supported_features() -> [atom()].
supported_features() ->
    [dynamic_domains].

-spec config_spec() -> mongoose_config_spec:config_section().
config_spec() ->
    #section{
       items = #{<<"backend">> => #option{type = binary, validate = {enum, [rdbms]}},
                 <<"message_as_implicit_marker">> => #option{type = boolean},
                 <<"keep_private">> => #option{type = boolean},
                 <<"iqdisc">> => mongoose_config_spec:iqdisc()
       }
    }.

%%--------------------------------------------------------------------
%% Hook handlers
%%--------------------------------------------------------------------

-spec process_iq(mongoose_acc:t(), jid:jid(), jid:jid(), jlib:iq(), map()) ->
    {mongoose_acc:t(), jlib:iq()}.
process_iq(Acc, _From, _To, #iq{type = set, sub_el = SubEl} = IQ, _Extra) ->
    {Acc, IQ#iq{type = error, sub_el = [SubEl, mongoose_xmpp_errors:not_allowed()]}};
process_iq(Acc, From, _To, #iq{type = get, sub_el = SubEl} = IQ, _Extra) ->
    Res = case maps:from_list(SubEl#xmlel.attrs) of
              #{<<"peer">> := BinPeer, <<"thread">> := Thread, <<"after">> := BinTS} ->
                  fetch_markers(IQ, Acc, From, jid:from_binary(BinPeer), Thread, parse_ts(BinTS));
              #{<<"peer">> := BinPeer, <<"thread">> := Thread} ->
                  fetch_markers(IQ, Acc, From, jid:from_binary(BinPeer), Thread, 0);
              #{<<"peer">> := BinPeer, <<"after">> := BinTS} ->
                  fetch_markers(IQ, Acc, From, jid:from_binary(BinPeer), undefined, parse_ts(BinTS));
              #{<<"peer">> := BinPeer} ->
                  fetch_markers(IQ, Acc, From, jid:from_binary(BinPeer), undefined, 0);
              #{} ->
                  Msg = <<"No peer provided">>,
                  IQ#iq{type = error, sub_el = [mongoose_xmpp_errors:bad_request(<<"en">>, Msg)]}
          end,
    {Acc, Res}.

-spec parse_ts(binary()) -> integer() | error.
parse_ts(BinTS) ->
    try calendar:rfc3339_to_system_time(binary_to_list(BinTS))
    catch error:_Error -> error
    end.

-spec fetch_markers(jlib:iq(),
                   mongoose_acc:t(),
                   jid:jid(),
                   error | jid:jid(),
                   maybe_thread(),
                   error | integer()) -> jlib:iq().
fetch_markers(IQ, _, _, error, _, _) ->
    IQ#iq{type = error,
          sub_el = [mongoose_xmpp_errors:bad_request(<<"en">>, <<"invalid-peer">>)]};
fetch_markers(IQ, _, _, _, _, error) ->
    IQ#iq{type = error,
          sub_el = [mongoose_xmpp_errors:bad_request(<<"en">>, <<"invalid-timestamp">>)]};
fetch_markers(IQ, Acc, From, Peer, Thread, TS) ->
    HostType = mongoose_acc:host_type(Acc),
    Markers = mod_smart_markers_backend:get_conv_chat_marker(HostType, From, Peer, Thread, TS),
    SubEl = #xmlel{name = <<"query">>,
                   attrs = [{<<"xmlns">>, ?NS_ESL_SMART_MARKERS},
                            {<<"peer">>, jid:to_binary(jid:to_lus(Peer))}],
                   children = build_result(Markers)},
    IQ#iq{type = result, sub_el = SubEl}.

build_result(Markers) ->
    [ #xmlel{name = <<"marker">>,
             attrs = [{<<"id">>, MsgId},
                      {<<"type">>, atom_to_binary(Type)},
                      {<<"timestamp">>, ts_to_bin(MsgTS)}
                      | maybe_thread(MsgThread) ]}
      || #{thread := MsgThread, type := Type, timestamp := MsgTS, id := MsgId} <- Markers ].

ts_to_bin(TS) ->
    list_to_binary(calendar:system_time_to_rfc3339(TS, [{offset, "Z"}, {unit, microsecond}])).

maybe_thread(undefined) ->
    [];
maybe_thread(Bin) ->
    [{<<"thread">>, Bin}].

%% @TODO: implement all the other hooks
-spec hooks(mongooseim:host_type()) -> [ejabberd_hooks:hook()].
hooks(HostType) ->
    [{user_send_packet, HostType, ?MODULE, user_send_packet, 90},
     {remove_user, HostType, ?MODULE, remove_user, 60},
     {remove_domain, HostType, ?MODULE, remove_domain, 60},
     {forget_room, HostType, ?MODULE, forget_room, 85},
     {room_new_affiliations, HostType, ?MODULE, room_new_affiliations, 60}
    ].

-spec user_send_packet(mongoose_acc:t(), jid:jid(), jid:jid(), exml:element()) ->
	mongoose_acc:t().
user_send_packet(Acc, From, To, Packet = #xmlel{name = <<"message">>}) ->
    case has_valid_markers(Acc, From, To, Packet) of
        {true, HostType, Markers} ->
            update_chat_markers(Acc, HostType, Markers);
        false -> Acc
    end;
user_send_packet(Acc, _From, _To, _Packet) ->
    Acc.

remove_user(Acc, User, Server) ->
    HostType = mongoose_acc:host_type(Acc),
    mod_smart_markers_backend:remove_user(HostType, jid:make_bare(User, Server)),
    Acc.

-spec remove_domain(mongoose_hooks:simple_acc(),
                    mongooseim:host_type(), jid:lserver()) ->
    mongoose_hooks:simple_acc().
remove_domain(Acc, HostType, Domain) ->
    mod_smart_markers_backend:remove_domain(HostType, Domain),
    Acc.

-spec forget_room(mongoose_hooks:simple_acc(), mongooseim:host_type(), jid:lserver(), jid:luser()) ->
    mongoose_hooks:simple_acc().
forget_room(Acc, HostType, RoomS, RoomU) ->
    mod_smart_markers_backend:remove_to(HostType, jid:make_noprep(RoomU, RoomS, <<>>)),
    Acc.

%% IDEA 2: the new affs can be found in the Acc:element, where we can scan for 'none' ones
-spec room_new_affiliations(mongoose_acc:t(), jid:jid(), mod_muc_light:aff_users(), binary()) ->
    mongoose_acc:t().
room_new_affiliations(Acc, RoomJid, _NewAffs, _NewVersion) ->
    HostType = mod_muc_light_utils:acc_to_host_type(Acc),
    Packet = mongoose_acc:element(Acc),
    case exml_query:paths(Packet, [{element_with_ns, ?NS_MUC_LIGHT_AFFILIATIONS},
                                   {element_with_attr, <<"affiliation">>, <<"none">>},
                                   cdata]) of
        [] -> Acc;
        Users ->
            [begin
                 FromJid = jid:to_bare(jid:from_binary(User)),
                 mod_smart_markers_backend:remove_to_for_user(HostType, FromJid, RoomJid)
             end || User <- Users ],
            Acc
    end.
%% IDEA 1: is the user, as extracted from Acc:from_jid, a member of the NewAffs?!
    % FromJid = mongoose_acc:from_jid(Acc),
    % case [ US || {US, _} <- NewAffs, jid:are_bare_equal(FromJid, US) ] of
    %     [] -> Acc;
    %     [_] ->
    %         mod_smart_markers_backend:remove_to_for_user(HostType, FromJid, RoomJid),
    %         Acc
    % end.

%%--------------------------------------------------------------------
%% Other API
%%--------------------------------------------------------------------
-spec get_chat_markers(jid:jid(), maybe_thread(), integer()) ->
    [chat_marker()].
get_chat_markers(#jid{lserver = LServer} = To, Thread, TS) ->
    %% internal API, no room access rights verification here!
    {ok, HostType} = mongoose_domain_api:get_host_type(LServer),
    mod_smart_markers_backend:get_chat_markers(HostType, To, Thread, TS).

%%--------------------------------------------------------------------
%% Local functions
%%--------------------------------------------------------------------
-spec update_chat_markers(mongoose_acc:t(), mongooseim:host_type(), [chat_marker()]) ->
    mongoose_acc:t().
update_chat_markers(Acc, HostType, Markers) ->
    TS = mongoose_acc:timestamp(Acc),
    [mod_smart_markers_backend:update_chat_marker(HostType, CM) || CM <- Markers],
    mongoose_acc:set_permanent(?MODULE, timestamp, TS, Acc).

-spec has_valid_markers(mongoose_acc:t(), jid:jid(), jid:jid(), exml:element()) ->
    false | {true, mongooseim:host_type(), Markers :: [chat_marker()]}.
has_valid_markers(Acc, From, To, Packet) ->
    case extract_chat_markers(Acc, From, To, Packet) of
        [] -> false;
        Markers ->
            case is_valid_host(Acc, From, To) of
                false -> false;
                {true, HostType} -> {true, HostType, Markers}
            end
    end.

-spec is_valid_host(mongoose_acc:t(), jid:jid(), jid:jid()) ->
    false | {true, mongooseim:host_type()}.
is_valid_host(Acc, From, To) ->
    case mongoose_acc:stanza_type(Acc) of
        <<"groupchat">> -> get_host(Acc, From, To, groupchat);
        _ -> get_host(Acc, From, To, one2one)
    end.

-spec extract_chat_markers(mongoose_acc:t(), jid:jid(), jid:jid(), exml:element()) ->
	[chat_marker()].
extract_chat_markers(Acc, From, To, Packet) ->
    case mongoose_chat_markers:list_chat_markers(Packet) of
        [] -> [];
        ChatMarkers ->
            TS = mongoose_acc:timestamp(Acc),
            CM = #{from => From,
                   to => To,
                   thread => get_thread(Packet),
                   timestamp => TS,
                   type => undefined,
                   id => undefined},
            [CM#{type => Type, id => Id} || {Type, Id} <- ChatMarkers]
    end.

-spec get_thread(exml:element()) -> maybe_thread().
get_thread(El) ->
    case exml_query:path(El, [{element, <<"thread">>}, cdata]) of
        Thread when Thread =/= <<>> -> Thread;
        _ -> undefined
    end.

-spec get_host(mongoose_acc:t(), jid:jid(), jid:jid(), chat_type()) ->
    false | {true, mongooseim:host_type()}.
get_host(Acc, From, To, groupchat) ->
    HostType = mod_muc_light_utils:room_jid_to_host_type(To),
    can_access_room(HostType, Acc, From, To) andalso {true, HostType};
get_host(_Acc, _From, To, one2one) ->
    LServer = To#jid.lserver,
    case mongoose_domain_api:get_domain_host_type(LServer) of
        {ok, HostType} -> {true, HostType};
        {error, not_found} -> false
    end.

-spec can_access_room(HostType :: mongooseim:host_type(),
                      Acc :: mongoose_acc:t(),
                      User :: jid:jid(),
                      Room :: jid:jid()) -> boolean().
can_access_room(HostType, Acc, User, Room) ->
    mongoose_hooks:can_access_room(HostType, Acc, Room, User).
