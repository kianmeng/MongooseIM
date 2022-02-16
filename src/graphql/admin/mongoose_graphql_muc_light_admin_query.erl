-module(mongoose_graphql_muc_light_admin_query).

-export([execute/4]).

-ignore_xref([execute/4]).

-include("../mongoose_graphql_types.hrl").

-import(mongoose_graphql_helper, [make_error/2, format_result/2]).
-import(mongoose_graphql_muc_light_helper, [make_room/1, make_ok_user/1]).

execute(_Ctx, _Obj, <<"listUserRooms">>, Args) ->
    list_user_rooms(Args);
execute(_Ctx, _Obj, <<"listRoomUsers">>, Args) ->
    list_room_users(Args);
execute(_Ctx, _Obj, <<"getRoomConfig">>, Args) ->
    get_room_config(Args);
execute(_Ctx, _Obj, <<"getRoomMessages">>, Args) ->
    get_room_messages(Args).

-spec list_user_rooms(map()) -> {ok, [binary()]} | {error, resolver_error()}.
list_user_rooms(#{<<"user">> := UserJID}) ->
    case mod_muc_light_api:get_user_rooms(UserJID) of
        {ok, Rooms} ->
            {ok, [{ok, R} || R <- Rooms]};
        Err ->
            make_error(Err, #{})
    end.

-spec list_room_users(map()) -> {ok, [map()]} | {error, resolver_error()}.
list_room_users(#{<<"domain">> := Domain, <<"id">> := RoomID}) ->
    case mod_muc_light_api:get_room_aff(Domain, RoomID) of
        {ok, Affs} ->
            {ok, [make_ok_user(A) || A <- Affs]};
        Err ->
            make_error(Err, #{})
    end.

-spec get_room_config(map()) -> {ok, map()} | {error, resolver_error()}.
get_room_config(#{<<"domain">> := Domain, <<"id">> := RoomID}) ->
    case mod_muc_light_api:get_room_info(Domain, RoomID) of
        {ok, Room} ->
            {ok, make_room(Room)};
        Err ->
            make_error(Err, #{})
    end.

-spec get_room_messages(map()) -> {ok, map()} | {error, resolver_error()}.
get_room_messages(#{<<"domain">> := Domain, <<"id">> := RoomID}) ->
    case mod_muc_light_api:get_room_messages(Domain, RoomID) of
        {ok, Rows} ->
            Maps = lists:map(fun mongoose_graphql_stanza_helper:row_to_map/1, Rows),
            {ok, #{<<"stanzas">> => Maps, <<"limit">> => null}};
        Err ->
            make_error(Err, #{})
    end.
