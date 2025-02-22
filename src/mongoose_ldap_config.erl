-module(mongoose_ldap_config).

%% Config spec
-export([uids/0,
         dn_filter/0,
         local_filter/0]).

%% Config spec callbacks
-export([process_uids/1,
         process_dn_filter/1,
         process_local_filter/1]).

-include("mongoose_config_spec.hrl").

uids() ->
    #section{
       items = #{<<"attr">> => #option{type = binary},
                 <<"format">> => #option{type = binary}},
       process = fun ?MODULE:process_uids/1,
       required = [<<"attr">>],
       format_items = map
      }.

dn_filter() ->
    #section{
       items = #{<<"filter">> => #option{type = binary,
                                         validate = ldap_filter},
                 <<"attributes">> => #list{items = #option{type = binary}}
                },
       required = [<<"filter">>],
       defaults = #{<<"attributes">> => []},
       process = fun ?MODULE:process_dn_filter/1,
       format_items = map
      }.

local_filter() ->
    #section{
       items = #{<<"operation">> => #option{type = atom,
                                            validate = {enum, [equal, notequal]}},
                 <<"attribute">> => #option{type = string,
                                            validate = non_empty},
                 <<"values">> => #list{items = #option{type = string},
                                       validate = non_empty}
                },
       required = all,
       process = fun ?MODULE:process_local_filter/1,
       format_items = map
      }.

process_uids(#{attr := Attr, format := Format}) -> {Attr, Format};
process_uids(#{attr := Attr}) -> Attr.

process_dn_filter(#{filter := Filter, attributes := Attrs}) ->
    {Filter, Attrs}.

process_local_filter(#{operation := Op, attribute := Attr, values := Values}) ->
    {Op, {Attr, Values}}.
