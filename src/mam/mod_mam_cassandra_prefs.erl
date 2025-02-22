%%%-------------------------------------------------------------------
%%% @author Uvarov Michael <arcusfelis@gmail.com>
%%% @copyright (C) 2013, Uvarov Michael
%%% @doc A backend for storing MAM preferencies using Cassandra.
%%% @end
%%%-------------------------------------------------------------------
-module(mod_mam_cassandra_prefs).
-behaviour(mongoose_cassandra).

%% ----------------------------------------------------------------------
%% Exports

%% gen_mod handlers
-export([start/2, stop/1]).

%% MAM hook handlers
-behaviour(ejabberd_gen_mam_prefs).
-export([get_behaviour/5,
         get_prefs/4,
         set_prefs/7,
         remove_archive/4]).

-export([prepared_queries/0]).

-ignore_xref([remove_archive/4, start/2, stop/1]).

-include("mongoose.hrl").
-include("jlib.hrl").
-include_lib("exml/include/exml.hrl").

-type host_type() :: mongooseim:host_type().

%% ----------------------------------------------------------------------
%% gen_mod callbacks
%% Starting and stopping functions for users' archives

-spec start(host_type(), _) -> ok.
start(HostType, _Opts) ->
    ejabberd_hooks:add(hooks(HostType)).

-spec stop(host_type()) -> ok.
stop(HostType) ->
    ejabberd_hooks:delete(hooks(HostType)).

%% ----------------------------------------------------------------------
%% Hooks

hooks(HostType) ->
    case gen_mod:get_module_opt(HostType, ?MODULE, pm, false) of
        true -> pm_hooks(HostType);
        false -> []
    end ++
    case gen_mod:get_module_opt(HostType, ?MODULE, muc, false) of
        true -> muc_hooks(HostType);
        false -> []
    end.

pm_hooks(HostType) ->
    [{mam_get_behaviour, HostType, ?MODULE, get_behaviour, 50},
     {mam_get_prefs, HostType, ?MODULE, get_prefs, 50},
     {mam_set_prefs, HostType, ?MODULE, set_prefs, 50},
     {mam_remove_archive, HostType, ?MODULE, remove_archive, 50}].

muc_hooks(HostType) ->
    [{mam_muc_get_behaviour, HostType, ?MODULE, get_behaviour, 50},
     {mam_muc_get_prefs, HostType, ?MODULE, get_prefs, 50},
     {mam_muc_set_prefs, HostType, ?MODULE, set_prefs, 50},
     {mam_muc_remove_archive, HostType, ?MODULE, remove_archive, 50}].

%% ----------------------------------------------------------------------

prepared_queries() ->
    [
     {set_prefs_ts_query,
      "INSERT INTO mam_config(user_jid, remote_jid, behaviour) VALUES (?, ?, ?) USING TIMESTAMP ?"},
     {get_prefs_query,
      "SELECT remote_jid, behaviour FROM mam_config WHERE user_jid = ?"},
     {get_behaviour_bare_query,
      "SELECT remote_jid, behaviour FROM mam_config WHERE user_jid = ? AND remote_jid IN ('', ?)"},
     {get_behaviour_full_query,
      "SELECT remote_jid, behaviour FROM mam_config WHERE user_jid = ? AND remote_jid "
      "IN ('', :start_remote_jid, :end_remote_jid)"},
     {del_prefs_ts_query,
      "DELETE FROM mam_config USING TIMESTAMP ? WHERE user_jid = ?"}
    ].

%% ----------------------------------------------------------------------
%% Internal functions and callbacks

-spec get_behaviour(Default :: mod_mam:archive_behaviour(),
                    HostType :: host_type(), ArchiveID :: mod_mam:archive_id(),
                    LocJID :: jid:jid(), RemJID :: jid:jid()) -> any().
get_behaviour(DefaultBehaviour, HostType, _UserID, LocJID, RemJID) ->
    BUserJID = mod_mam_utils:bare_jid(LocJID),
    BRemBareJID = mod_mam_utils:bare_jid(RemJID),
    BRemJID = mod_mam_utils:full_jid(RemJID),
    case query_behaviour(HostType, LocJID, BUserJID, BRemJID, BRemBareJID) of
        {ok, []} ->
            DefaultBehaviour;
        {ok, [_ | _] = Rows} ->
            %% After sort <<>>, <<"a">>, <<"a/b">>
            SortedRows = lists:sort(
                fun(#{remote_jid := JID1, behaviour := B1},
                    #{remote_jid := JID2, behaviour := B2}) ->
                    {JID1, B1} < {JID2, B2}
                end, Rows),
            #{behaviour := Behaviour} = lists:last(SortedRows),
            decode_behaviour(Behaviour)
    end.


-spec set_prefs(Result :: any(), HostType :: host_type(),
                ArchiveID :: mod_mam:archive_id(), ArchiveJID :: jid:jid(),
                DefaultMode :: mod_mam:archive_behaviour(),
                AlwaysJIDs :: [jid:literal_jid()],
                NeverJIDs :: [jid:literal_jid()]) -> any().
set_prefs(_Result, HostType, _UserID, UserJID, DefaultMode, AlwaysJIDs, NeverJIDs) ->
    try
        set_prefs1(HostType, UserJID, DefaultMode, AlwaysJIDs, NeverJIDs)
    catch Type:Error:StackTrace ->
              ?LOG_ERROR(#{what => mam_set_prefs_failed,
                           user_jid => UserJID, default_mode => DefaultMode,
                           always_jids => AlwaysJIDs, never_jids => NeverJIDs,
                           class => Type, reason => Error, stacktrace => StackTrace}),
            {error, Error}
    end.

set_prefs1(HostType, UserJID, DefaultMode, AlwaysJIDs, NeverJIDs) ->
    BUserJID = mod_mam_utils:bare_jid(UserJID),
    %% Force order of operations using timestamps
    %% http://stackoverflow.com/questions/30317877/cassandra-batch-statement-execution-order
    Now = mongoose_cassandra:now_timestamp(),
    Next = Now + 1,
    DelParams = #{'[timestamp]' => Now, user_jid => BUserJID},
    MultiParams = [encode_row(BUserJID, <<>>, encode_behaviour(DefaultMode), Next)]
        ++ [encode_row(BUserJID, BinJID, <<"A">>, Next) || BinJID <- AlwaysJIDs]
        ++ [encode_row(BUserJID, BinJID, <<"N">>, Next) || BinJID <- NeverJIDs],
    DelQuery = {del_prefs_ts_query, [DelParams]},
    SetQuery = {set_prefs_ts_query, MultiParams},
    Queries = [DelQuery, SetQuery],
    Res = [mongoose_cassandra:cql_write(pool_name(HostType), UserJID, ?MODULE, Query, Params)
           || {Query, Params} <- Queries],
    ?LOG_DEBUG(#{what => mam_set_prefs, user_jid => UserJID, default_mode => DefaultMode,
                 always_jids => AlwaysJIDs, never_jids => NeverJIDs, result => Res}),
    ok.

encode_row(BUserJID, BRemoteJID, Behaviour, Timestamp) ->
    #{user_jid => BUserJID, remote_jid => BRemoteJID,
      behaviour => Behaviour, '[timestamp]' => Timestamp}.


-spec get_prefs(mod_mam:preference(), _HostType :: host_type(),
                ArchiveID :: mod_mam:archive_id(), ArchiveJID :: jid:jid())
               -> mod_mam:preference().
get_prefs({GlobalDefaultMode, _, _}, HostType, _UserID, UserJID) ->
    BUserJID = mod_mam_utils:bare_jid(UserJID),
    Params = #{user_jid => BUserJID},
    {ok, Rows} = mongoose_cassandra:cql_read(pool_name(HostType), UserJID, ?MODULE,
                                             get_prefs_query, Params),
    decode_prefs_rows(Rows, GlobalDefaultMode, [], []).


-spec remove_archive(mongoose_acc:t(), host_type(), mod_mam:archive_id(), jid:jid()) ->
    mongoose_acc:t().
remove_archive(Acc, HostType, _UserID, UserJID) ->
    remove_archive(HostType, UserJID),
    Acc.

remove_archive(HostType, UserJID) ->
    BUserJID = mod_mam_utils:bare_jid(UserJID),
    Now = mongoose_cassandra:now_timestamp(),
    Params = #{'[timestamp]' => Now, user_jid => BUserJID},
    mongoose_cassandra:cql_write(pool_name(HostType), UserJID,
                                 ?MODULE, del_prefs_ts_query, [Params]).

-spec query_behaviour(host_type(), UserJID :: jid:jid(), BUserJID :: binary() | string(),
                      BRemJID :: binary() | string(), BRemBareJID :: binary() | string()) -> any().
query_behaviour(HostType, UserJID, BUserJID, BRemJID, BRemBareJID)
  when BRemJID == BRemBareJID ->
    Params = #{user_jid => BUserJID, remote_jid => BRemBareJID},
    mongoose_cassandra:cql_read(pool_name(HostType), UserJID, ?MODULE,
                                get_behaviour_bare_query, Params);
query_behaviour(HostType, UserJID, BUserJID, BRemJID, BRemBareJID) ->
    Params = #{user_jid => BUserJID, start_remote_jid => BRemJID,
               end_remote_jid => BRemBareJID},
    mongoose_cassandra:cql_read(pool_name(HostType), UserJID, ?MODULE,
                                get_behaviour_full_query, Params).

%% ----------------------------------------------------------------------
%% Helpers

-spec encode_behaviour('always' | 'never' | 'roster') -> binary().
encode_behaviour(roster) -> <<"R">>;
encode_behaviour(always) -> <<"A">>;
encode_behaviour(never) -> <<"N">>.


-spec decode_behaviour(<<_:8>>) -> 'always' | 'never' | 'roster'.
decode_behaviour(<<"R">>) -> roster;
decode_behaviour(<<"A">>) -> always;
decode_behaviour(<<"N">>) -> never.

-spec decode_prefs_rows([[term()]], DefaultMode, AlwaysJIDs, NeverJIDs) ->
    {DefaultMode, AlwaysJIDs, NeverJIDs} when
        DefaultMode :: mod_mam:archive_behaviour(),
        AlwaysJIDs :: [jid:literal_jid()],
        NeverJIDs :: [jid:literal_jid()].
decode_prefs_rows([], DefaultMode, AlwaysJIDs, NeverJIDs) ->
    {DefaultMode, AlwaysJIDs, NeverJIDs};

decode_prefs_rows([#{remote_jid := <<>>, behaviour := Behaviour} | Rows],
                  _DefaultMode, AlwaysJIDs, NeverJIDs) ->
    decode_prefs_rows(Rows, decode_behaviour(Behaviour), AlwaysJIDs, NeverJIDs);
decode_prefs_rows([#{remote_jid := JID, behaviour := <<"A">>} | Rows],
                  DefaultMode, AlwaysJIDs, NeverJIDs) ->
    decode_prefs_rows(Rows, DefaultMode, [JID | AlwaysJIDs], NeverJIDs);
decode_prefs_rows([#{remote_jid := JID, behaviour := <<"N">>} | Rows],
                  DefaultMode, AlwaysJIDs, NeverJIDs) ->
    decode_prefs_rows(Rows, DefaultMode, AlwaysJIDs, [JID | NeverJIDs]).

%% ----------------------------------------------------------------------
%% Params getters

-spec pool_name(HostType :: host_type()) -> term().
pool_name(HostType) ->
    gen_mod:get_module_opt(HostType, ?MODULE, pool_name, default).
