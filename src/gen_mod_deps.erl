%%==============================================================================
%% Copyright 2016 Erlang Solutions Ltd.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%==============================================================================

-module(gen_mod_deps).

-include("mongoose.hrl").

-type hardness() :: soft | hard | optional.
-type module_deps_list() :: [{module(), gen_mod_params(), hardness()}].
-type gen_mod_params() :: proplists:proplist().
-type gen_mod_list() :: [{module(), gen_mod_params()}].
-type gen_mod_map() :: #{module() => gen_mod_params()}.

-export([add_deps/2, resolve_deps/2, sort_deps/2]).

-ignore_xref([add_deps/2]).

-export_type([hardness/0, gen_mod_params/0, gen_mod_list/0, gen_mod_map/0]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Adds deps into module list.
%% Side-effect free.
-spec add_deps(Host :: jid:server(), Modules :: gen_mod_map() | gen_mod_list()) -> gen_mod_list().
add_deps(Host, Modules) ->
    sort_deps(Host, resolve_deps(Host, Modules)).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

%% Resolving dependencies

%% @doc
%% Determines all modules to start, along with their parameters.
%%
%% NOTE: A dependency will not be discarded during resolving, e.g.
%% if the resolver processes dependencies in order:
%%
%% deps(mod_a, []) -> [{mod_b, []}, {mod_c, []}]
%% deps(mod_parent, []) -> [{mod_a, [param]}]
%%
%% then the dependency for mod_a will be reevaluated with new parameters and
%% might return:
%%
%% deps(mod_a, [param]) -> [{mod_c, []}]
%%
%% In this case, mod_b will still be started.
%% @end
-spec resolve_deps(Host :: jid:server(), Modules :: gen_mod_map() | gen_mod_list()) -> gen_mod_map().
resolve_deps(Host, Modules) when is_map(Modules) ->
    resolve_deps(Host, maps:to_list(Modules));
resolve_deps(Host, ModuleQueue) ->
    resolve_deps(Host, ModuleQueue, #{}, #{}).

-spec resolve_deps(Host :: jid:server(),
                   Modules :: [{module(), gen_mod_params()} | {module(), gen_mod_params(), hardness()}],
                   OptionalQueue :: #{module() => gen_mod_params()},
                   Acc :: gen_mod_map()) -> gen_mod_map().
resolve_deps(Host, [], OptionalMods, KnownModules) ->
    KnownModNames = maps:keys(KnownModules),
    case maps:with(KnownModNames, OptionalMods) of
        NewQueueMap when map_size(NewQueueMap) > 0 ->
            resolve_deps(Host, maps:to_list(NewQueueMap),
                         maps:without(KnownModNames, OptionalMods), KnownModules);
        _Nothing ->
            KnownModules
    end;
resolve_deps(Host, [{Module, Args, optional} | ModuleQueue], OptionalMods, KnownModules) ->
    resolve_deps(Host, ModuleQueue, maps:put(Module, Args, OptionalMods), KnownModules);
resolve_deps(Host, [{Module, Args, _Hardness} | ModuleQueue], OptionalMods, KnownModules) ->
    resolve_deps(Host, [{Module, Args} | ModuleQueue], OptionalMods, KnownModules);
resolve_deps(Host, [{Module, Args} | ModuleQueue], OptionalMods, KnownModules) ->
    NewArgs =
        case maps:find(Module, KnownModules) of
            {ok, PreviousArgs} ->
                case merge_args(Module, PreviousArgs, Args) of
                    PreviousArgs -> undefined;
                    ChangedArgs -> ChangedArgs
                end;

            error ->
                Args
        end,

    case NewArgs of
        undefined -> resolve_deps(Host, ModuleQueue, OptionalMods, KnownModules);
        _ ->
            Deps = get_deps(Host, Module, NewArgs),
            UpdatedQueue = Deps ++ ModuleQueue,
            UpdatedKnownModules = maps:put(Module, NewArgs, KnownModules),
            resolve_deps(Host, UpdatedQueue, OptionalMods, UpdatedKnownModules)
    end.

%% @doc
%% Merges proplists prioritizing the new list, and warns on overrides.
%% @end
-spec merge_args(Module :: module(), PreviousArgs :: gen_mod_params(),
                 Args :: gen_mod_params()) -> gen_mod_params().
merge_args(Module, PreviousArgs, Args) ->
    lists:foldl(
      fun(Property, OldProplist) ->
              [{Key, Value}] = proplists:unfold([Property]),
              case proplists:lookup(Key, OldProplist) of
                  none ->
                      [Property | OldProplist];

                  {_, Value} ->
                      OldProplist;

                  {_, OldValue} ->
                      ?LOG_WARNING(#{what => overriding_argument, module => Module,
                                     old_value => {Key, OldValue},
                                     new_value => {Key, Value}}),

                      [Property | proplists:delete(Key, OldProplist)]
              end
      end, PreviousArgs, Args).

%% Sorting resolved dependencies

-spec sort_deps(Host :: jid:server(), ModuleMap :: gen_mod_map()) ->
                       gen_mod_list().
sort_deps(Host, ModuleMap) ->
    DepsGraph = digraph:new([acyclic, private]),

    try
        maps:fold(
          fun(Module, Args, _) ->
                  process_module_dep(Host, Module, Args, DepsGraph)
          end,
          undefined, ModuleMap),

        lists:filtermap(
          fun(Module) ->
                  case maps:find(Module, ModuleMap) of
                      error -> false;
                      {ok, Opts} -> {true, {Module, Opts}}
                  end
          end,
          digraph_utils:topsort(DepsGraph))
    after
        digraph:delete(DepsGraph)
    end.


-spec process_module_dep(Host :: jid:server(), Module :: module(),
                         Args :: gen_mod_params(),
                         DepsGraph :: digraph:graph()) -> ok.
process_module_dep(Host, Module, Args, DepsGraph) ->
    digraph:add_vertex(DepsGraph, Module),
    lists:foreach(
      fun({DepModule, _, DepHardness}) -> process_dep(Module, DepModule, DepHardness, DepsGraph) end,
      get_deps(Host, Module, Args)).


-spec process_dep(Module :: module(), DepModule :: module(),
                  DepHardness :: hardness(), Graph :: digraph:graph()) -> ok.
process_dep(Module, DepModule, DepHardness, Graph) ->
    digraph:add_vertex(Graph, DepModule),
    case {digraph:add_edge(Graph, DepModule, Module, DepHardness), DepHardness} of
        {['$e' | _], _} ->
            ok;

        {{error, {bad_edge, CyclePath}}, hard} ->
            case find_soft_edge(Graph, CyclePath) of
                false ->
                    ?LOG_CRITICAL(#{what => resolving_dependencies_aborted,
                                    text => <<"Module dependency cycle found">>,
                                    cycle_path => CyclePath}),
                    error({dependency_cycle, CyclePath});

                {EdgeId, B, A, _} ->
                    ?LOG_INFO(#{what => soft_module_dependency_cycle_detected,
                                text => <<"Soft module dependency cycle detected. "
                                          "Dropping edge">>, edge => {A, B},
                                cyclepath => CyclePath}),

                    digraph:del_edge(Graph, EdgeId),
                    ['$e' | _] = digraph:add_edge(Graph, DepModule, Module, hard),
                    ok
            end;

        {{error, {bad_edge, CyclePath}}, _Soft} ->
            ?LOG_INFO(#{what => soft_module_dependency_cycle_detected,
                        text => <<"Soft module dependency cycle detected. "
                                  "Dropping edge">>, edge => {Module, DepModule},
                        cyclepath => CyclePath}),
            ok
    end.


-spec find_soft_edge(digraph:graph(), [digraph:vertex()]) ->
                            {digraph:edge(), digraph:vertex(),
                             digraph:vertex(), digraph:label()} | false.
find_soft_edge(Graph, CyclePath) ->
    VerticePairs = lists:zip(CyclePath, tl(CyclePath) ++ [hd(CyclePath)]),
    Edges = lists:filtermap(
              fun({A, B}) ->
                      case find_edge(Graph, A, B) of
                          false -> false;
                          Edge -> {true, digraph:edge(Graph, Edge)}
                      end
              end,
              VerticePairs),

    case lists:keyfind(optional, 4, Edges) of
        false -> lists:keyfind(soft, 4, Edges);
        Edge -> Edge
    end.


-spec find_edge(digraph:graph(), digraph:vertex(), digraph:vertex()) ->
                       digraph:edge() | false.
find_edge(Graph, A, B) ->
    OutEdges = ordsets:from_list(digraph:out_edges(Graph, A)),
    InEdges = ordsets:from_list(digraph:in_edges(Graph, B)),

    case ordsets:intersection(OutEdges, InEdges) of
        [Edge] -> Edge;
        [] -> false
    end.


-spec get_deps(Host :: jid:server(), module(), gen_mod_params()) -> module_deps_list().
get_deps(Host, Module, Args) ->
    lists:map(
      fun
          ({Mod, Hardness}) -> {Mod, [], Hardness};
          ({Mod, ModArgs, Hardness}) -> {Mod, ModArgs, Hardness}
             end,
      gen_mod:get_deps(Host, Module, Args)).
