%% Copyright 2009, 2010, 2011 Anton Lavrik
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%%
%% @doc Piqi-RPC runtime support library
%%

-module(piqi_rpc).

-compile(export_all).


-include("piqi_rpc_piqi.hrl").


%-define(DEBUG, 1).
-include("debug.hrl").


% TODO: -specs, doc


call(Mod, Name) ->
    ?PRINT({call, Mod, Name}),
    check_function_exported(Mod, Name, 0),
    Mod:Name().


call(Mod, Name, Input) ->
    ?PRINT({call, Mod, Name, Input}),
    check_function_exported(Mod, Name, 1),
    Mod:Name(Input).


check_function_exported(Mod, Name, Arity) ->
    case erlang:function_exported(Mod, Name, Arity) of
        true -> ok;
        false ->
            Error = lists:concat([
                "function ", Mod, ":", Name, "/", Arity, " is not exported"]),
            throw_rpc_error({'internal_error', list_to_binary(Error)})
    end.


get_piqi(BinPiqiList, _OutputFormat = 'pb') ->
    % return the Piqi module and all the dependencies encoded as a list of Piqi
    % each encoded using Protobuf binary format
    piqirun:gen_list('undefined', fun piqirun:binary_to_block/2, BinPiqiList);

get_piqi(BinPiqiList, OutputFormat) -> % piq (i.e. text/plain), json, xml
    L = [ convert_piqi(X, OutputFormat) || X <- BinPiqiList ],
    string:join(L, "\n\n").


convert(TypeName, InputFormat, OutputFormat, Data) ->
    try
        piqi_tools:convert(TypeName, InputFormat, OutputFormat, Data)
    catch
        % Piqi tools has exited, but hasn't been restarted by Piqi-RPC monitor
        % yet
        exit:{noproc, _} ->
            % wait for the first restart attempt -- it should be really fast
            case piqi_rpc_monitor:get_status() of
                'active' ->
                    % retry the request
                    piqi_tools:convert(TypeName, InputFormat, OutputFormat, Data);
                _ ->
                    % XXX, TODO: return "service unavailable" instead of
                    % "internal error"
                    throw_rpc_error({'internal_error', "service temporarily unavailable"})
            end
    end.


convert_piqi(BinPiqi, OutputFormat) ->
    {ok, Bin} = convert("piqi", 'pb', OutputFormat, BinPiqi),
    binary_to_list(Bin).


decode_input(_Decoder, _TypeName, _InputFormat, 'undefined') ->
    throw_rpc_error('missing_input');

decode_input(Decoder, TypeName, InputFormat, InputData) ->
    BinInput =
        % NOTE: converting anyway even in the input is encoded using 'pb'
        % encoding to check the validity
        case convert(TypeName, InputFormat, 'pb', InputData) of
            {ok, X} -> X;
            {error, Error} ->
                throw_rpc_error({'invalid_input', Error})
        end,
    Buf = piqirun:init_from_binary(BinInput),
    Decoder(Buf).


encode_common(Encoder, TypeName, OutputFormat, Output) ->
    IolistOutput = Encoder('undefined', Output),
    BinOutput = iolist_to_binary(IolistOutput),
    case OutputFormat of
        'pb' -> {ok, BinOutput}; % already in needed format
        _ -> convert(TypeName, 'pb', OutputFormat, BinOutput)
    end.


encode_output(Encoder, TypeName, OutputFormat, Output) ->
    case encode_common(Encoder, TypeName, OutputFormat, Output) of
        {ok, OutputData} -> {ok, OutputData};
        {error, Error} ->
            throw_rpc_error(
                {'invalid_output', "error converting output: " ++ Error})
    end.


encode_error(Encoder, TypeName, OutputFormat, Output) ->
    case encode_common(Encoder, TypeName, OutputFormat, Output) of
        {ok, ErrorData} -> {error, ErrorData};
        {error, Error} ->
            throw_rpc_error(
                {'invalid_output', "error converting error: " ++ Error})
    end.


-spec throw_rpc_error/1 :: (Error :: piqi_rpc_rpc_error()) -> none().
throw_rpc_error(Error) ->
    throw({'rpc_error', Error}).


%
% Error handlers
%

check_empty_input('undefined') -> ok;
check_empty_input(_) ->
    throw_rpc_error({'invalid_input', "empty input expected"}).


handle_unknown_function() ->
    throw_rpc_error('unknown_function').


handle_invalid_result(Name, Result) ->
    % XXX: limit the size of the returned Reason string by using "~P"?
    ResultStr = io_lib:format("~p", [Result]),
    Error = ["function ", Name, " returned invalid result: ", ResultStr],
    throw_rpc_error({'internal_error', iolist_to_binary(Error)}).


% already got the error formatted properly by one of the above handlers
handle_runtime_exception(throw, {'rpc_error', _} = X) -> X;
handle_runtime_exception(Class, Reason) ->
    % XXX: limit the size of the returned Reason string by using "~P"?
    Error = io_lib:format("~w:~p, stacktrace: ~p",
        [Class, Reason, erlang:get_stacktrace()]),
    {'rpc_error', {'internal_error', iolist_to_binary(Error)}}.

