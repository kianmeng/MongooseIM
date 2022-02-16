-module(mod_muc_light_api).

-export([create_room/5,
         invite_to_room/4,
         change_room_config/5,
         change_affiliation/5,
         remove_user_from_room/4,
         send_message/4,
         delete_room/3,
         delete_room/2,
         delete_room/1,
         get_room_messages/2,
         get_user_rooms/1,
         get_room_info/2,
         get_room_aff/2
        ]).
-ignore_xref([delete_room/1]).

-include("mod_muc_light.hrl").
-include("mongoose.hrl").
-include("jlib.hrl").
-include("mongoose_rsm.hrl").

-type create_room_result() :: {ok, room()} | {exist |
                                              max_occupants_reached |
                                              bad_request |
                                              validation_error , iolist()}.

-type invite_to_room_result() :: {ok | forbidden | not_found, iolist()}.

-type change_room_config_result() :: {ok, room()} | {wrong_user |
                                                     not_allowed |
                                                     validation_error |
                                                     bad_request, iolist()}.

-type get_room_messages_result() :: {ok, []} | {not_supported |
                                                policy_violation |
                                                internal, iolist()}.
-type room() :: #{jid := jid:jid(),
                 name := binary(),
                 subject := binary(),
                 aff_users := aff_users()
                }.

-export_type([room/0, create_room_result/0]).

-spec create_room(jid:lserver(), binary(), binary(), jid:jid(), binary()) -> create_room_result().
create_room(Domain, RoomId, RoomTitle, CreatorJID, Subject) ->
    LServer = jid:nameprep(Domain),
    HostType = mod_muc_light_utils:server_host_to_host_type(LServer),
    MUCLightDomain = mod_muc_light_utils:server_host_to_muc_host(HostType, LServer),
    MUCServiceJID = jid:make(RoomId, MUCLightDomain, <<>>),
    Config = make_room_config(RoomTitle, Subject),
    case mod_muc_light:try_to_create_room(CreatorJID, MUCServiceJID, Config) of
        {ok, RoomJID, #create{aff_users = AffUsers}} ->
            {ok, make_room(RoomJID, RoomTitle, Subject, AffUsers)};
        {error, exists} ->
            {exist, "Room already exists"};
        {error, max_occupants_reached} ->
            {max_occupants_reached, "Max occupants number reached"};
        {error, bad_request} ->
            {bad_request, "Bad request"};
        {error, {Key, Reason}} ->
            {validation_error, io_lib:format("Validation failed for key: ~p with reason ~p",
                                             [Key, Reason])}
    end.


-spec invite_to_room(jid:lserver(), binary(), jid:jid(), jid:jid()) -> invite_to_room_result().
invite_to_room(Domain, RoomName, SenderJID, RecipientJID) ->
    % FIXME use id instead of roomname because room name is not unique
    RecipientBin = jid:to_binary(jid:to_bare(RecipientJID)),
    case muc_light_room_name_to_jid_and_aff(SenderJID, RoomName, Domain) of
        {ok, R, _Aff} ->
            S = jid:to_bare(SenderJID),
            Changes = query(?NS_MUC_LIGHT_AFFILIATIONS,
                            [affiliate(RecipientBin, <<"member">>)]),
            ejabberd_router:route(S, R, iq(jid:to_binary(S), jid:to_binary(R),
                                           <<"set">>, [Changes])),
            {ok, "User invited successfully"};
        {error, given_user_does_not_occupy_any_room} ->
            {forbidden, "Given user does not occupy any room"};
        {error, not_exists} ->
            {not_exists, "Room does not exist"}
    end.

-spec change_room_config(jid:lserver(), binary(), binary(), jid:jid(), binary()) ->
    change_room_config_result().
change_room_config(Domain, RoomID, RoomName, UserJID, Subject) ->
    LServer = jid:nameprep(Domain),
    HostType = mod_muc_light_utils:server_host_to_host_type(LServer),
    MUCLightDomain = mod_muc_light_utils:server_host_to_muc_host(HostType, LServer),
    UserUS = jid:to_bare(UserJID),
    ConfigReq = #config{ raw_config =
                         [{<<"roomname">>, RoomName}, {<<"subject">>, Subject}]},
    Acc = mongoose_acc:new(#{location => ?LOCATION, lserver => LServer, host_type => HostType}),
    case mod_muc_light:change_room_config(UserUS, RoomID, MUCLightDomain, ConfigReq, Acc) of
        {ok, RoomJID, _}  ->
            {ok, make_room(RoomJID, RoomName, Subject, [])};
        {error, item_not_found} ->
            {wrong_user, "The given user is not room participant"};
        {error, not_allowed} ->
            {not_allowed, "The given user has not permission to change config"};
        {error, {error, {Key, Reason}}} ->
            {validation_error, io_lib:format("Validation failed for key: ~p with reason ~p",
                                             [Key, Reason])};
        {error, bad_request} ->
            {bad_request, "Bad request"}
    end.

-spec change_affiliation(jid:lserver(), binary(), jid:jid(), jid:jid(), binary()) -> ok.
change_affiliation(Domain, RoomID, SenderJID, RecipientJID, Affiliation) ->
    RecipientJID2 = jid:to_bare(RecipientJID),
    LServer = jid:nameprep(Domain),
    HostType = mod_muc_light_utils:server_host_to_host_type(LServer),
    MUCLightDomain = mod_muc_light_utils:server_host_to_muc_host(HostType, LServer),
    R = jid:make(RoomID, MUCLightDomain, <<>>),
    S = jid:to_bare(SenderJID),
    Changes = query(?NS_MUC_LIGHT_AFFILIATIONS,
                    [affiliate(jid:to_binary(RecipientJID2), Affiliation)]),
    ejabberd_router:route(S, R, iq(jid:to_binary(S), jid:to_binary(R),
                                   <<"set">>, [Changes])),
    ok.

-spec remove_user_from_room(jid:lserver(), binary(), jid:jid(), jid:jid()) -> {ok, iolist()}.
remove_user_from_room(Domain, RoomID, SenderJID, RecipientJID) ->
    change_affiliation(Domain, RoomID, SenderJID, RecipientJID, <<"none">>),
    {ok, io_lib:format("User ~s kicked successfully", [jid:to_binary(RecipientJID)])}.

-spec send_message(jid:lserver(), binary(), jid:jid(), binary()) -> {ok | wrong_user, iolist()}.
send_message(Domain, RoomName, SenderJID, Message) ->
    Body = #xmlel{name = <<"body">>,
                  children = [ #xmlcdata{ content = Message } ]
                 },
    Stanza = #xmlel{name = <<"message">>,
                    attrs = [{<<"type">>, <<"groupchat">>}],
                    children = [ Body ]
                   },
    S = jid:to_bare(SenderJID),
    case get_user_rooms(jid:to_lus(S), Domain) of
        [] ->
            {wrong_user, "Given user does not occupy any room"};
        RoomJIDs when is_list(RoomJIDs) ->
            FindFun = find_room_and_user_aff_by_room_name(RoomName, jid:to_lus(S)),
            {ok, {RU, RS}, _Aff} = lists:foldl(FindFun, none, RoomJIDs),
            true = is_subdomain(RS, Domain),
            R = jid:make(RU, RS, <<>>),
            ejabberd_router:route(S, R, Stanza),
            {ok, "Message send successfully"}
    end.

-spec delete_room(jid:lserver(), binary(), jid:jid()) ->
    { ok | not_exists | not_allowed | user_without_room, iolist()}.
delete_room(Domain, RoomName, OwnerJID) ->
    %% FIXME use id instead of name
    OwnerJID2 = jid:to_bare(OwnerJID),
    Res = case muc_light_room_name_to_jid_and_aff(OwnerJID2, RoomName, Domain) of
              {ok, RoomJID, owner} ->
                  mod_muc_light:delete_room(jid:to_lus(RoomJID));
              {ok, _, _} ->
                  {error, not_allowed};
              {error, _} = Err ->
                  Err
          end,
    format_delete_error_message(Res).

-spec delete_room(jid:lserver(), binary()) -> { ok | not_exists, iolist()}.
delete_room(Domain, RoomID) ->
    LServer = jid:nameprep(Domain),
    HostType = mod_muc_light_utils:server_host_to_host_type(LServer),
    MUCLightDomain = mod_muc_light_utils:server_host_to_muc_host(HostType, LServer),
    Res = mod_muc_light:delete_room({RoomID, MUCLightDomain}),
    format_delete_error_message(Res).


-spec delete_room(jid:jid()) -> { ok | not_exists, iolist()}.
delete_room(RoomJID) ->
    Res = mod_muc_light:delete_room(jid:to_lus(RoomJID)),
    format_delete_error_message(Res).

-spec get_room_messages(jid:lserver(), binary()) -> get_room_messages_result().
get_room_messages(Domain, RoomID) ->
    HostType = mod_muc_light_utils:server_host_to_host_type(Domain),
    MUCLightDomain = mod_muc_light_utils:server_host_to_muc_host(HostType, jid:nameprep(Domain)),
    RoomJID = jid:make_bare(RoomID, MUCLightDomain),
    Now = os:system_time(microsecond),
    ArchiveID = mod_mam_muc:archive_id_int(HostType, RoomJID),
    PageSize = 50,
    %End = 100000,
    RSM = #rsm_in{direction = before, id = undefined},
    R = mod_mam_muc:lookup_messages(HostType,
                                    #{archive_id => ArchiveID,
                                      owner_jid => RoomJID,
                                      %caller_jid => jid:from_binary(<<jid@localhost>>),
                                      rsm => RSM,
                                      borders => undefined,
                                      start_ts => undefined,
                                      end_ts => Now,
                                      now => Now,
                                      with_jid => undefined,
                                      search_text => undefined,
                                      page_size => PageSize,
                                      limit_passed => true,
                                      max_result_limit => 50,
                                      is_simple => true}),
    case R of
        {ok, {_, _, Messages}} ->
            {ok, Messages};
        {error, 'not-supported'} ->
            {not_supported, "Text search is not supported"};
        {error, 'policy-violation'} ->
            {policy_violation, "Policy violation"};
        {error, Term} ->
            {internal, io_lib:format("Internal error occured ~p", [Term])}
    end.

-spec get_room_info(jid:lserver(), binary()) -> {ok, map()} | {not_exists, iolist()}.
get_room_info(Domain, RoomID) ->
    HostType = mod_muc_light_utils:server_host_to_host_type(Domain),
    MUCServer = mod_muc_light_utils:server_host_to_muc_host(HostType, Domain),
    case mod_muc_light_db_backend:get_info(HostType, {RoomID, MUCServer}) of
        {ok, [{roomname, Name}, {subject, Subject}], AffUsers, _Version} ->
            {ok, make_room(jid:make_bare(RoomID, MUCServer), Name, Subject, AffUsers)};
        {error, not_exists} ->
            {not_exists, "Room not exists"}
    end.

-spec get_room_aff(jid:lserver(), binary()) -> {ok, [aff_user()]} | {not_exists, iolist()}.
get_room_aff(Domain, RoomID) ->
    case get_room_info(Domain, RoomID) of
        {ok, #{aff_users := AffUsers}} ->
            {ok, AffUsers};
        Err ->
            Err
    end.

-spec get_user_rooms(jid:jid()) -> {ok, [RoomUS :: jid:simple_bare_jid()]} | {not_found, iolist()}.
get_user_rooms(#jid{lserver = LServer} = UserJID) ->
    case get_muc_tuple(LServer) of
        {ok, HostType, MUCServer} ->
            UserUS = jid:to_lus(UserJID),
            {ok, mod_muc_light_db_backend:get_user_rooms(HostType, UserUS, MUCServer)};
        {error, not_found} ->
            {not_found, "Given domain doesn't exist"}
    end.

 %% Internal

-spec get_muc_tuple(jid:lserver()) -> {ok, mongooseim:host_type(), jid:lserver()} |
                                      {error, not_found}.
get_muc_tuple(LServer) ->
    case mongoose_domain_api:get_domain_host_type(LServer) of
        {ok, HostType} ->
            {ok, HostType, mod_muc_light_utils:server_host_to_muc_host(HostType, LServer)};
        Error ->
            Error
    end.

make_room(JID, Name, Subject, AffUsers) ->
    #{jid => JID, name => Name, subject => Subject, aff_users => AffUsers}.

format_delete_error_message(ok) ->
    {ok, "Room deleted successfully!"};
format_delete_error_message({error, not_allowed}) ->
    {not_allowed, "You cannot delete this room"};
format_delete_error_message({error, not_exists}) ->
    {not_exists, "Cannot remove not existing room"};
format_delete_error_message({error, given_user_does_not_occupy_any_room}) ->
    {user_without_room, "Given user does not occupy this room"}.

iq(To, From, Type, Children) ->
    UUID = uuid:uuid_to_string(uuid:get_v4(), binary_standard),
    #xmlel{name = <<"iq">>,
           attrs = [{<<"from">>, From},
                    {<<"to">>, To},
                    {<<"type">>, Type},
                    {<<"id">>, UUID}],
           children = Children
          }.

query(NS, Children) when is_binary(NS), is_list(Children) ->
    #xmlel{name = <<"query">>,
           attrs = [{<<"xmlns">>, NS}],
           children = Children
          }.

affiliate(JID, Kind) when is_binary(JID), is_binary(Kind) ->
    #xmlel{name = <<"user">>,
           attrs = [{<<"affiliation">>, Kind}],
           children = [ #xmlcdata{ content = JID } ]
          }.


-spec make_room_config(binary(), binary()) -> create_req_props().
make_room_config(Name, Subject) ->
    #create{raw_config = [{<<"roomname">>, Name},
                          {<<"subject">>, Subject}]
           }.

-spec muc_light_room_name_to_jid_and_aff(UserJID :: jid:jid(),
                                         RoomName :: binary(),
                                         Domain :: jid:lserver()) ->
    {ok, jid:jid(), aff()} | {error, given_user_does_not_occupy_any_room} | {error, not_exists}.
muc_light_room_name_to_jid_and_aff(UserJID, RoomName, Domain) ->
    UserUS = jid:to_lus(UserJID),
    case get_user_rooms(UserUS, Domain) of
        [] ->
            {error, given_user_does_not_occupy_any_room};
        RoomUSs when is_list(RoomUSs) ->
            FindFun = find_room_and_user_aff_by_room_name(RoomName, UserUS),
            case lists:foldl(FindFun, none, RoomUSs) of
                {ok, {RU, RS}, UserAff} ->
                    true = is_subdomain(RS, Domain),
                    {ok, jid:make(RU, RS, <<>>), UserAff};
                none ->
                    {error, not_exists}
            end
    end.

-spec get_user_rooms(UserUS :: jid:simple_bare_jid(), Domain :: jid:lserver()) ->
    [jid:simple_bare_jid()].
get_user_rooms({_, UserS} = UserUS, Domain) ->
    HostType = mod_muc_light_utils:server_host_to_host_type(UserS),
    mod_muc_light_db_backend:get_user_rooms(HostType, UserUS, Domain).

-spec get_room_name_and_user_aff(RoomUS :: jid:simple_bare_jid(),
                                 UserUS :: jid:simple_bare_jid()) ->
    {ok, RoomName :: binary(), UserAff :: aff()} | {error, not_exists}.
get_room_name_and_user_aff(RoomUS, {_, UserS} = UserUS) ->
    HostType = mod_muc_light_utils:server_host_to_host_type(UserS),
    case mod_muc_light_db_backend:get_info(HostType, RoomUS) of
        {ok, Cfg, Affs, _} ->
            {roomname, RoomName} = lists:keyfind(roomname, 1, Cfg),
            {_, UserAff} = lists:keyfind(UserUS, 1, Affs),
            {ok, RoomName, UserAff};
        Error ->
            Error
    end.

-type find_room_acc() :: {ok, RoomUS :: jid:simple_bare_jid(), UserAff :: aff()} | none.

-spec find_room_and_user_aff_by_room_name(RoomName :: binary(),
                                          UserUS :: jid:simple_bare_jid()) ->
    fun((RoomUS :: jid:simple_bare_jid(), find_room_acc()) -> find_room_acc()).
find_room_and_user_aff_by_room_name(RoomName, UserUS) ->
    fun (RoomUS, none) ->
            case get_room_name_and_user_aff(RoomUS, UserUS) of
                {ok, RoomName, UserAff} ->
                    {ok, RoomUS, UserAff};
                _ ->
                    none
            end;
        (_, Acc) when Acc =/= none ->
            Acc
    end.

is_subdomain(Child, Parent) ->
    %% Example input Child = <<"muclight.localhost">> and Parent =
    %% <<"localhost">>
    case binary:match(Child, Parent) of
        nomatch -> false;
        {_, _} -> true
    end.
