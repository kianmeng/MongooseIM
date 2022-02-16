-module(mongoose_graphql_admin_query).

-export([execute/4]).

-ignore_xref([execute/4]).

-include("../mongoose_graphql_types.hrl").

execute(_Ctx, _Obj, <<"domains">>, _Args) ->
    {ok, admin};
execute(_Ctx, _Obj, <<"account">>, _Args) ->
    {ok, account};
execute(_Ctx, _Obj, <<"muc_light">>, _Args) ->
    {ok, muc_light};
execute(_Ctx, _Obj, <<"session">>, _Opts) ->
    {ok, session};
execute(_Ctx, _Obj, <<"stanza">>, _Opts) ->
    {ok, #{}};
execute(#{authorized := Authorized}, _Obj, <<"checkAuth">>, _Args) ->
    case Authorized of
        true ->
            {ok, 'AUTHORIZED'};
        false ->
            {ok, 'UNAUTHORIZED'}
    end.
