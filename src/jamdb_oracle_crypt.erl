-module(jamdb_oracle_crypt).

-export([o5logon/2]).
-export([validate/2]).

-include("jamdb_oracle.hrl").

%%====================================================================
%% callbacks
%%====================================================================

%o3logon(Sess, KeySess, Pass) ->
%    IVec = <<0:64>>,
%    SrvSess = crypto:block_decrypt(des_cbc, binary:part(KeySess,0,8), IVec, Sess),
%    N = (8 - (length(Pass) rem 8 )) rem 8,
%    CliPass = <<(list_to_binary(Pass))/binary, (binary:copy(<<0>>, N))/binary>>,
%    AuthPass = crypto:block_encrypt(des_cbc, binary:part(SrvSess,0,8), IVec, CliPass),
%    {bin2hexstr(AuthPass)++[N], [], []}.

o5logon(#logon{auth=Sess, user=User, password=Pass}, Bits) when Bits =:= 128 ->
    IVec = <<0:64>>,
    CliPass = norm(User++Pass),
    Rest1 = crypto:block_encrypt(des_cbc, hexstr2bin("0123456789ABCDEF"), IVec, CliPass),
    Rest2 = crypto:block_encrypt(des_cbc, binary:part(Rest1,byte_size(Rest1),-8), IVec, CliPass),
    KeySess = <<(binary:part(Rest2,byte_size(Rest2),-8))/binary,0:64>>,
    o5logon(#logon{auth=hexstr2bin(Sess), key=KeySess, password=Pass, bits=Bits});
o5logon(#logon{auth=Sess, salt=Salt, password=Pass}, Bits) when Bits =:= 192 ->
    Data = crypto:hash(sha,<<(list_to_binary(Pass))/binary,(hexstr2bin(Salt))/binary>>),
    KeySess = <<Data/binary,0:32>>,
    o5logon(#logon{auth=hexstr2bin(Sess), key=KeySess, password=Pass, bits=Bits});
o5logon(#logon{auth=Sess, salt=Salt, der_salt=DerivedSalt, password=Pass}, Bits) when Bits =:= 256 ->
    Data = pbkdf2(sha512, 4096, 64, Pass, <<(hexstr2bin(Salt))/binary,"AUTH_PBKDF2_SPEEDY_KEY">>),
    KeySess = binary:part(crypto:hash(sha512, <<Data/binary, (hexstr2bin(Salt))/binary>>),0,32),
    o5logon(#logon{auth=hexstr2bin(Sess), key=KeySess, password=Pass, bits=Bits,
    der_salt=DerivedSalt, der_key = <<(pad(16,<<>>))/binary, Data/binary>>}).

o5logon(#logon{auth=Sess, key=KeySess, der_salt=DerivedSalt, der_key=DerivedKey, password=Pass, bits=Bits}) ->
    IVec = <<0:128>>,
    SrvSess = jose_jwa_aes:block_decrypt({aes_cbc, Bits}, KeySess, IVec, Sess),
    CliSess = crypto:strong_rand_bytes(byte_size(SrvSess)),
    AuthSess = jose_jwa_aes:block_encrypt({aes_cbc, Bits}, KeySess, IVec, CliSess),
    CatKey = cat_key(SrvSess, CliSess, Bits),
    KeyConn = conn_key(CatKey, DerivedSalt, Bits),
    AuthPass = jose_jwa_aes:block_encrypt({aes_cbc, Bits}, KeyConn, IVec, pad(Pass)),
    SpeedyKey =
    case DerivedKey of
        undefined -> <<>>;
        _ -> jose_jwa_aes:block_encrypt({aes_cbc, Bits}, KeyConn, IVec, DerivedKey)
    end,
    {bin2hexstr(AuthPass), bin2hex(AuthSess), bin2hexstr(SpeedyKey), KeyConn}.

validate(Resp, KeyConn) ->
    IVec = <<0:128>>,
    Bits = byte_size(KeyConn) * 8,
    Data = jose_jwa_aes:block_decrypt({aes_cbc, Bits}, KeyConn, IVec, hexstr2bin(Resp)),
    case binary:match(Data,<<"SERVER_TO_CLIENT">>) of
	nomatch -> error;
	_ -> ok
    end.

%%====================================================================
%% Internal misc
%%====================================================================

conn_key(Data, undefined, Bits) when Bits =:= 128 ->
    <<(erlang:md5(Data))/binary>>;
conn_key(Data, undefined, Bits) when Bits =:= 192 ->
    <<(erlang:md5(binary:part(Data,0,16)))/binary,
      (binary:part(erlang:md5(binary:part(Data,16,8)),0,8))/binary>>;
conn_key(Data, DerivedSalt, Bits) when Bits =:= 256 ->
    pbkdf2(sha512, 3, 32, bin2hexstr(Data), hexstr2bin(DerivedSalt)).

cat_key(X,Y,Bits) when Bits =:= 128 ->
    cat_key(binary:part(X,byte_size(X),-16),binary:part(Y,byte_size(Y),-16),[]);
cat_key(X,Y,Bits) when Bits =:= 192 ->
    cat_key(binary:part(X,16,24),binary:part(Y,16,24),[]);
cat_key(X,Y,Bits) when Bits =:= 256 ->
    <<Y/binary,X/binary>>;
cat_key(<<>>,<<>>,S) ->
    list_to_binary(S);
cat_key(<<H, X/bits>>,<<L, Y/bits>>,S) ->
    cat_key(X,Y,S++[H bxor L]).

norm(Data) ->
    S = norm(list_to_binary(Data),[]),
    N = (8 - (length(S) rem 8 )) rem 8,
    <<(list_to_binary(S))/binary, (binary:copy(<<0>>, N))/binary>>.

norm(<<>>,S) ->
    S;
norm(<<U/utf8,R/binary>>,S) ->
    C = case U of
	N when N > 255 -> 63;
	N when N >= 97, N =< 122 -> N-32;
	N -> N
    end,
    norm(R,S++[0,C]).

pad(S) ->
    P = 16 - (length(S) rem 16),
    <<(pad(16,<<>>))/binary, (pad(P,list_to_binary(S)))/binary>>.

pad(P, Bin) -> <<Bin/binary, (binary:copy(<<P>>, P))/binary>>.

hexstr2bin(S) ->
    list_to_binary(hexstr2list(S)).

hexstr2list([X,Y|T]) ->
    [mkint(X)*16 + mkint(Y) | hexstr2list(T)];
hexstr2list([]) ->
    [].
mkint(C) when $0 =< C, C =< $9 ->
    C - $0;
mkint(C) when $A =< C, C =< $F ->
    C - $A + 10;
mkint(C) when $a =< C, C =< $f ->
    C - $a + 10.

bin2hexstr(Bin) when is_binary(Bin) ->
    binary_to_list(bin2hex(Bin)).

bin2hex(Bin) when is_binary(Bin) ->
    << <<(mkhex(H)),(mkhex(L))>> || <<H:4,L:4>> <= Bin >>.
mkhex(C) when C < 10 -> $0 + C;
mkhex(C) -> $A + C - 10.

pbkdf2(Type, Iterations, Length, Pass, Salt) ->
    Mac = fun(Key, Data) -> crypto:hmac(Type, Key, Data) end,
    pbkdf2(Mac, 1, 1, Iterations, Length, Pass, Salt, <<>>).

pbkdf2(Mac, Reps, Reps, Iterations, Length, Pass, Salt, Acc) ->
    << Key:Length/binary, _/binary >> =
    << Acc/binary, (pbkdf2_exor(Mac, Pass, Salt, 1, Iterations, Reps, <<>>, <<>>))/binary >>,
    Key;
pbkdf2(Mac, Num, Reps, Iterations, Length, Pass, Salt, Acc) ->
    pbkdf2(Mac, Num + 1, Reps, Iterations, Length, Pass, Salt,
    << Acc/binary, (pbkdf2_exor(Mac, Pass, Salt, 1, Iterations, Num, <<>>, <<>>))/binary >>).

pbkdf2_exor(_Mac, _Pass, _Salt, I, Iterations, _Num, _Prev, Acc) when I > Iterations ->
    Acc;
pbkdf2_exor(Mac, Pass, Salt, I = 1, Iterations, Num, <<>>, <<>>) ->
    Next = Mac(Pass, << Salt/binary, Num:1/integer-unit:32 >>),
    pbkdf2_exor(Mac, Pass, Salt, I + 1, Iterations, Num, Next, Next);
pbkdf2_exor(Mac, Pass, Salt, I, Iterations, Num, Prev, Acc) ->
    Next = Mac(Pass, Prev),
    pbkdf2_exor(Mac, Pass, Salt, I + 1, Iterations, Num, Next, crypto:exor(Next, Acc)).
