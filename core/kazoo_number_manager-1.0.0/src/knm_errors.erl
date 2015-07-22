%%%-------------------------------------------------------------------
%%% @copyright (C) 2015, 2600Hz INC
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   Peter Defebvre
%%%-------------------------------------------------------------------
-module(knm_errors).

-export([to_json/1, to_json/2]).

-include("knm.hrl").

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec to_json(any()) -> wh_json:object().
-spec to_json(any(), ne_binary() | number()) -> wh_json:object().
to_json(Reason)->
    to_json(Reason, 'undefined').

to_json('not_found', Num) ->
    Message = <<"number ", Num/binary, " not found">>,
    build_error(404, 'not_found', Message, Num);
to_json('not_reconcilable', Num) ->
    Message = <<"number ", Num/binary, " is not reconcilable">>,
    build_error(404, 'not_found', Message, Num);
to_json('unauthorized', Num) ->
    Message = <<"operation on ", Num/binary, " unauthorized">>,
    build_error(403, 'forbidden', Message, 'undefined');
to_json(Reason, _Num) ->
    build_error(500, 'unspecified_fault', Reason, 'undefined').

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec build_error(integer(), any(), any(), any()) -> wh_json:object().
build_error(Code, Error, Message, Cause) ->
    wh_json:from_list(
        props:filter_undefined([
            {<<"code">>, Code}
            ,{<<"error">>, to_binary(Error)}
            ,{<<"cause">>, to_binary(Cause)}
            ,{<<"message">>, to_binary(Message)}
        ])
    ).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec to_binary(any()) -> binary().
to_binary('undefined') -> 'undefined';
to_binary(Any) -> wh_util:to_binary(Any).