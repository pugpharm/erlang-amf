%% @author Ruslan Babayev <ruslan@babayev.com>
%% @copyright 2009 Ruslan Babayev
%% @doc AMF0 Encoding and Decoding.

-module(amf0).
-author('ruslan@babayev.com').

-export([encode/1, decode/1]).

-define(NUMBER,        16#00).
-define(BOOL,          16#01).
-define(STRING,        16#02).
-define(OBJECT,        16#03).
-define(MOVIECLIP,     16#04).
-define(NULL,          16#05).
-define(UNDEFINED,     16#06).
-define(REFERENCE,     16#07).
-define(ECMAARRAY,     16#08).
-define(OBJECTEND,     16#09).
-define(STRICTARRAY,   16#0A).
-define(DATE,          16#0B).
-define(LONGSTRING,    16#0C).
-define(UNSUPPORTED,   16#0D).
-define(RECORDSET,     16#0E).
-define(XMLDOCUMENT,   16#0F).
-define(TYPEDOBJECT,   16#10).
-define(AVMPLUSOBJECT, 16#11).

%% IEEE 754 special values
-define(POS_INFINITY, <<0:1,16#7FF:11,0:52>>).
-define(NEG_INFINITY, <<1:1,16#7FF:11,0:52>>).
-define(QNAN,         <<0:1,16#7FF:11,1:1,0:51>>).
-define(SNAN,         <<0:1,16#7FF:11,0:1,1:51>>).

%% @type members() = [{atom(), amf0()}].
%% @type object() = {object, members()}.
%% @type typed_object() = {object, Class::binary(), members()}.
%% @type date() = {date, MilliSecs::float(), TimeZone::integer()}.
%% @type xmldoc() = {xmldoc, Contents::binary()}.
%% @type ecma_array() = [{binary(), amf0()}].
%% @type strict_array() = [amf0()].
%% @type avmplus() = {avmplus, amf3()}.
%% @type double() = float() | '+infinity' | '-infinity' | 'qNan' | 'sNaN'.
%% @type amf0() = double() | bool() | binary() | object() | null |
%%                undefined | ecma_array() | strict_array() | date() |
%%                typed_object() | xmldoc() | avmplus().
%% @type refs() = //stdlib/gb_trees:gb_tree()

%% @doc Decodes a value.
%% @spec decode(binary()) -> {Value::amf0(), Rest::binary()}
decode(Bytes) ->
    {AMF, Rest, _Objects} = decode(Bytes, gb_trees:empty()),
    {AMF, Rest}.

%% @doc Decodes a value.
%% @spec decode(Bytes::binary(), Objects) -> {Value::amf0(), Rest, Objects}
%%       Objects = refs()
decode(<<?NUMBER, Data:8/binary, Rest/binary>>, Objects) ->
    {decode_double(Data), Rest, Objects};
decode(<<?BOOL, Bool, Rest/binary>>, Objects) ->
    {(Bool /= 0), Rest, Objects};
decode(<<?STRING, L:16, String:L/binary, Rest/binary>>, Objects) ->
    {String, Rest, Objects};
decode(<<?OBJECT, Data/binary>>, Objects) ->
    Key = gb_trees:size(Objects),
    Objects1 = gb_trees:insert(Key, {ref, Key}, Objects),
    {Members0, Objects2, Rest} = decode_members(Data, [], Objects1),
    Members1 = [{binary_to_atom(Name, utf8), Val} || {Name, Val} <- Members0],
    Object = {object, Members1},
    Objects3 = gb_trees:update(Key, Object, Objects2),
    {Object, Rest, Objects3};
decode(<<?NULL, Rest/binary>>, Objects) ->
    {null, Rest, Objects};
decode(<<?UNDEFINED, Rest/binary>>, Objects) ->
    {undefined, Rest, Objects};
decode(<<?REFERENCE, Num:16, Rest/binary>>, Objects) ->
    {gb_trees:get(Num, Objects), Rest, Objects};
decode(<<?ECMAARRAY, _Size:32, Data/binary>>, Objects) ->
    Key = gb_trees:size(Objects),
    Objects1 = gb_trees:insert(Key, {ref, Key}, Objects),
    {Array, Objects2, Rest} = decode_members(Data, [], Objects1),
    Objects3 = gb_trees:update(Key, Array, Objects2),
    {Array, Rest, Objects3};
decode(<<?STRICTARRAY, Size:32, Data/binary>>, Objects) ->
    Key = gb_trees:size(Objects),
    Objects1 = gb_trees:insert(Key, {ref, Key}, Objects),
    {Array, Objects2, Rest} = decode_array(Size, Data, [], Objects1),
    Objects3 = gb_trees:update(Key, Array, Objects2),
    {Array, Rest, Objects3};
decode(<<?DATE, TS:64/float, TZ:16/signed, Rest/binary>>, Objects) ->
    {{date, TS, TZ}, Rest, Objects};
decode(<<?LONGSTRING, L:32, String:L/binary, Rest/binary>>, Objects) ->
    {String, Rest, Objects};
decode(<<?UNSUPPORTED, Rest/binary>>, Objects) ->
    {unsupported, Rest, Objects};
decode(<<?XMLDOCUMENT, L:32, String:L/binary, Rest/binary>>, Objects) ->
    {{xmldoc, String}, Rest, Objects};
decode(<<?TYPEDOBJECT, L:16, Class:L/binary, Data/binary>>, Objects) ->
    Key = gb_trees:size(Objects),
    Objects1 = gb_trees:insert(Key, {ref, Key}, Objects),
    {Members0, Objects2, Rest} = decode_members(Data, [], Objects1),
    Members1 = [{binary_to_atom(Name, utf8), Val} || {Name, Val} <- Members0],
    Object = {object, Class, Members1},
    Objects3 = gb_trees:update(Key, Object, Objects2),
    {Object, Rest, Objects3};
decode(<<?AVMPLUSOBJECT, Data/binary>>, Objects) ->
    {AVMPlusObject, Rest} = amf3:decode(Data),
    {{avmplus, AVMPlusObject}, Rest, Objects}.

%% @doc Decodes IEEE-754 double precision floating-point number.
%% @spec decode_double(binary()) -> double()
decode_double(?POS_INFINITY)              -> '+infinity';
decode_double(?NEG_INFINITY)              -> '-infinity';
decode_double(<<_:1,16#7FF:11,1:1,_:51>>) -> 'qNaN';
decode_double(<<_:1,16#7FF:11,0:1,_:51>>) -> 'sNaN';
decode_double(<<Num:64/float>>)           -> Num.

%% @doc Decodes Object, Typed Object and ECMA Array members.
%% @spec decode_members(binary(), Acc, Objects) -> {members(), Objects, Rest}
%%       Objects = refs()
%%       Rest = binary()
decode_members(<<0:16, ?OBJECTEND, Rest/binary>>, Acc, Objects) ->
    {lists:reverse(Acc), Objects, Rest};
decode_members(<<L:16, Key:L/binary, Data/binary>>, Acc, Objects) ->
    {Value, Rest, Objects1} = decode(Data, Objects),
    decode_members(Rest, [{Key, Value} | Acc], Objects1).

%% @doc Decodes a Strict Array.
%% @spec decode_array(Size, Data, Acc, Objects) -> {Array, Objects, Rest}
%%       Array = strict_array()
%%       Objects = refs()
%%       Rest = binary()
decode_array(0, Rest, Acc, Objects) ->
    {lists:reverse(Acc), Objects, Rest};
decode_array(Size, Data, Acc, Objects) ->
    {Element, Rest, Objects1} = decode(Data, Objects),
    decode_array(Size - 1, Rest, [Element | Acc], Objects1). 

%% @doc Encodes a value.
%% @spec encode(amf0()) -> binary()
encode(Value) ->
    {Bin, _Objects} = encode(Value, gb_trees:empty()),
    Bin.

%% @doc Encodes a value.
%% @spec encode(Value::amf0(), Objects) -> {binary(), Objects}
%%       Objects = refs()
encode({avmplus, Object}, Objects) ->
    Bin = amf3:encode(Object),
    {<<?AVMPLUSOBJECT, Bin/binary>>, Objects};
encode('+infinity', Objects) ->
    {<<?NUMBER, ?POS_INFINITY/binary>>, Objects};
encode('-infinity', Objects) ->
    {<<?NUMBER, ?NEG_INFINITY/binary>>, Objects};
encode('qNaN', Objects) ->
    {<<?NUMBER, ?QNAN/binary>>, Objects};
encode('sNaN', Objects) ->
    {<<?NUMBER, ?SNAN/binary>>, Objects};
encode(Number, Objects) when is_number(Number) ->
    {<<?NUMBER, Number:64/float>>, Objects};
encode(true, Objects) ->
    {<<?BOOL, 1>>, Objects};
encode(false, Objects) ->
    {<<?BOOL, 0>>, Objects};
encode(String, Objects) when is_binary(String), size(String) =< 16#ffff ->
    {<<?STRING, (size(String)):16, String/binary>>, Objects};
encode(null, Objects) ->
    {<<?NULL>>, Objects};
encode(undefined, Objects) ->
    {<<?UNDEFINED>>, Objects};
encode({date, TS, TZ}, Objects) ->
    {<<?DATE, TS:64/float, TZ:16/signed>>, Objects};
encode(LongString, Objects)
  when is_binary(LongString), size(LongString) > 16#ffff ->
    {<<?LONGSTRING, (size(LongString)):32, LongString/binary>>, Objects};
encode(unsupported, Objects) ->
    {<<?UNSUPPORTED>>, Objects};
encode({xmldoc, String}, Objects) ->
    {<<?XMLDOCUMENT, (size(String)):32, String/binary>>, Objects};
encode({object, Members} = Object, Objects) ->
    case encode_as_reference(Object, gb_trees:iterator(Objects)) of
	{ok, Bin} ->
	    {Bin, Objects};
	inline ->
	    Key = gb_trees:size(Objects),
	    Objects1 = gb_trees:insert(Key, Object, Objects),
	    Members1 = [{atom_to_binary(N, utf8), V} || {N, V} <- Members],
	    {Bin, Objects2} = encode_members(Members1, <<>>, Objects1),
	    {<<?OBJECT, Bin/binary>>, Objects2}
    end;
encode({object, Class, Members} = Object, Objects) ->
    case encode_as_reference(Object, gb_trees:iterator(Objects)) of
	{ok, Bin} ->
	    {Bin, Objects};
	inline ->
	    Key = gb_trees:size(Objects),
	    Objects1 = gb_trees:insert(Key, Object, Objects),
	    Members1 = [{atom_to_binary(N, utf8), V} || {N, V} <- Members],
	    {Bin, Objects2} = encode_members(Members1, <<>>, Objects1),
	    Bin1 = <<?TYPEDOBJECT, (size(Class)):16, Class/binary,Bin/binary>>,
	    {Bin1, Objects2}
    end;
encode([{Name, _Val} | _] = List, Objects) when is_binary(Name) ->
    case encode_as_reference(List, gb_trees:iterator(Objects)) of
	{ok, Bin} ->
	    {Bin, Objects};
	inline ->
	    Key = gb_trees:size(Objects),
	    Objects1 = gb_trees:insert(Key, List, Objects),
	    {Bin, Objects2} = encode_members(List, <<>>, Objects1),
	    Bin1 = <<?ECMAARRAY, (length(List)):32, Bin/binary>>,
	    {Bin1, Objects2}
    end;
encode(List, Objects) when is_list(List) ->
    case encode_as_reference(List, gb_trees:iterator(Objects)) of
	{ok, Bin} ->
	    {Bin, Objects};
	inline ->
	    Key = gb_trees:size(Objects),
	    Objects1 = gb_trees:insert(Key, List, Objects),
	    {Bin, Objects2} = encode_array(List, <<>>, Objects1),
	    Bin1 = <<?STRICTARRAY, (length(List)):32, Bin/binary>>,
	    {Bin1, Objects2}
    end.

%% @doc Encodes Object, Typed Object and ECMA Array members.
%% @spec encode_members(Members, binary(), Objects) -> {binary(), Objects}
%%       Objects = refs()
encode_members([], Acc, Objects) ->
    {<<Acc/binary, 0:16, ?OBJECTEND>>, Objects};
encode_members([{Key, Val} | Rest], Acc, Objects) ->
    {ValBin, Objects1} = encode(Val, Objects),
    Bin = <<(size(Key)):16, Key/binary, ValBin/binary>>,
    encode_members(Rest, <<Acc/binary, Bin/binary>>, Objects1).

%% @doc Encodes a Strict Array.
%% @spec encode_array(Elements, binary(), Objects) -> {binary(), Objects}
%%       Objects = refs()
encode_array([], Acc, Objects) ->
    {Acc, Objects};
encode_array([Element | Rest], Acc, Objects) ->
    {Bin, Objects1} = encode(Element, Objects),
    encode_array(Rest, <<Acc/binary, Bin/binary>>, Objects1).

%% @doc Encodes a value as reference if it is found in Objects table.
%% @spec encode_as_reference(amf0(), Iterator) -> inline | {ok, binary()}
encode_as_reference(_Value, []) ->
    inline;
encode_as_reference(Value, Iterator0) ->
    case gb_trees:next(Iterator0) of
	{Key, Value, _} ->
	    {ok, <<?REFERENCE, Key:16>>};
	{_, _, Iterator1} ->
	    encode_as_reference(Value, Iterator1)
    end.
