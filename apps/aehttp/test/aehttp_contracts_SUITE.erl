-module(aehttp_contracts_SUITE).

%%
%% Each test assumes that the chain is at least at the height where the latest
%% consensus protocol applies hence each test reinitializing the chain should
%% take care of that at the end of the test.
%%

-include_lib("stdlib/include/assert.hrl").
-include_lib("aecore/include/aec_crypto.hrl").
%% common_test exports
-export(
   [
    all/0, groups/0, suite/0,
    init_per_suite/1, end_per_suite/1,
    init_per_group/2, end_per_group/2,
    init_per_testcase/2, end_per_testcase/2
   ]).

%% Endpoint calls
-export([]).

%% test case exports
%% external endpoints
-export([
	 spending_1/1,
	 identity_contract/1,
	 dutch_auction_contract_1/1,
	 dutch_auction_contract_2/1
	]).

-include_lib("common_test/include/ct.hrl").
-define(NODE, dev1).
-define(DEFAULT_TESTS_COUNT, 5).
-define(WS, aehttp_ws_test_utils).

all() ->
    [
     {group, contracts}
    ].

groups() ->
    [
     {contracts, [sequence],
      [
       spending_1
       %% identity_contract,
       %% identity_contract,
       %% dutch_auction_contract_1,
       %% dutch_auction_contract_2
      ]}
    ].

suite() ->
    [].

init_per_suite(Config) ->
    ok = application:ensure_started(erlexec),
    DataDir = ?config(data_dir, Config),
    TopDir = aecore_suite_utils:top_dir(DataDir),
    Config1 = [{symlink_name, "latest.http_endpoints"},
               {top_dir, TopDir},
               {test_module, ?MODULE}] ++ Config,
    aecore_suite_utils:make_shortcut(Config1),
    ct:log("Environment = ~p", [[{args, init:get_arguments()},
                                 {node, node()},
                                 {cookie, erlang:get_cookie()}]]),
    Forks = aecore_suite_utils:forks(),

    aecore_suite_utils:create_configs(Config1, #{<<"chain">> =>
                                                 #{<<"persist">> => true,
                                                   <<"hard_forks">> => Forks}}),
    aecore_suite_utils:make_multi(Config1, [?NODE]),
    [{nodes, [aecore_suite_utils:node_tuple(?NODE)]}]  ++ Config1.

end_per_suite(_Config) ->
    ok.

init_per_group(contracts, Config) ->
    NodeName = aecore_suite_utils:node_name(?NODE),
    aecore_suite_utils:start_node(?NODE, Config),
    aecore_suite_utils:connect(NodeName),

    %% Prepare accounts.
    {APubkey, APrivkey} = generate_key_pair(),
    {BPubkey, BPrivkey} = generate_key_pair(),
    {CPubkey, CPrivkey} = generate_key_pair(),
    {DPubkey, DPrivkey} = generate_key_pair(),
    AStartAmt = 50,
    BStartAmt = 50,
    CStartAmt = 50,
    DStartAmt = 50,
    Fee = 1,
    BlocksToMine = 1,				%Just a few

    %% Mine someblocks
    aecore_suite_utils:mine_blocks(aecore_suite_utils:node_name(?NODE),
				   BlocksToMine),
    %% Add 3 accounts and mine
    {ok, 200, _} = post_spend_tx(APubkey, AStartAmt, Fee),
    {ok, 200, _} = post_spend_tx(BPubkey, BStartAmt, Fee),
    {ok, 200, _} = post_spend_tx(CPubkey, CStartAmt, Fee),
    {ok, 200, _} = post_spend_tx(DPubkey, DStartAmt, Fee),
    {ok, [Block]} = aecore_suite_utils:mine_blocks(NodeName, 1),
    [_Spend1, _Spend2, _Spend3, _Spend4] = aec_blocks:txs(Block),
    assert_balance(APubkey, AStartAmt),
    assert_balance(BPubkey, BStartAmt),
    assert_balance(CPubkey, CStartAmt),
    assert_balance(DPubkey, DStartAmt),
    %% Save account information.
    Accounts = #{acc_a => #{pub_key => APubkey,
			    priv_key => APrivkey,
			    start_amt => AStartAmt},
		 acc_b => #{pub_key => BPubkey,
			    priv_key => BPrivkey,
			    start_amt => BStartAmt},
		 acc_c => #{pub_key => CPubkey,
			    priv_key => CPrivkey,
			    start_amt => CStartAmt},
		 acc_d => #{pub_key => DPubkey,
			    priv_key => DPrivkey,
			    start_amt => DStartAmt}},
    [{accounts,Accounts},{node_name,NodeName}|Config];
init_per_group(_Group, Config) ->
    aecore_suite_utils:start_node(?NODE, Config),
    aecore_suite_utils:connect(aecore_suite_utils:node_name(?NODE)),
    ToMine = aecore_suite_utils:latest_fork_height(),
    aecore_suite_utils:mine_blocks(aecore_suite_utils:node_name(?NODE),
                                   ToMine),
    Config.

end_per_group(all_endpoints, _Config) ->
    ok;
end_per_group(_Group, Config) ->
    RpcFun = fun(M, F, A) -> rpc(?NODE, M, F, A) end,
    {ok, DbCfg} = aecore_suite_utils:get_node_db_config(RpcFun),
    aecore_suite_utils:stop_node(?NODE, Config),
    aecore_suite_utils:delete_node_db_if_persisted(DbCfg),
    ok.

init_per_testcase(_Case, Config) ->
    [{tc_start, os:timestamp()}|Config].

end_per_testcase(_Case, Config) ->
    Ts0 = ?config(tc_start, Config),
    ct:log("Events during TC: ~p", [[{N, aecore_suite_utils:all_events_since(N, Ts0)}
                                     || {_,N} <- ?config(nodes, Config)]]),
    ok.

%% ============================================================
%% Test cases
%% ============================================================

%% spending_1(Config)
%%  Test case for experimenting with spending between accounts.
%%  Some results:
%%  - get_balance_at_top/0 seems really weird

spending_1(Config) ->
    NodeName = proplists:get_value(node_name, Config),
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
		 priv_key := APrivkey},
      acc_b := #{pub_key := BPubkey,
		 priv_key := BPrivkey}} = proplists:get_value(accounts, Config),

    %% Check initial balances.
    {ok,200,#{<<"balance">> := BTop0}} = get_balance_at_top(),
    ABal0 = get_balance(APubkey),
    BBal0 = get_balance(BPubkey),
    ct:pal("Balances 0: ~p, ~p\n", [ABal0,BBal0]),

    %% Add tokens to both accounts.
    {ok,200,_P0} = post_spend_tx(APubkey, 500, 1),
    {ok,200,_P1} = post_spend_tx(BPubkey, 500, 1),
    %%ct:pal("Spend ~p, ~p\n", [P0,P1]),

    {ok, [_Block]} = aecore_suite_utils:mine_blocks(NodeName, 1),

    %% Check balances after mining.
    ABal2 = get_balance(APubkey),
    BBal2 = get_balance(BPubkey),
    ct:pal("Balances 1: ~p, ~p\n", [ABal2,BBal2]),

    %% Transfer money from Alice to Bert.
    spend_tokens(APubkey, BPubkey, 200, 5, 1),
    aecore_suite_utils:mine_blocks(NodeName, 1),
    
    %% Check balances after sending.
    ABal3 = get_balance(APubkey),
    BBal3 = get_balance(BPubkey),
    ct:pal("Balances 2: ~p, ~p\n", [ABal3,BBal3]),

    %% Show the initial and final balances, whatever they are.
    {ok,200,#{<<"balance">> := BTop1}} = get_balance_at_top(),
    ct:pal("Balance at top: ~p, ~p, ~p \n", [BTop0,BTop1,BTop1-BTop0]),

    ok.
    
get_balance(Pubkey) ->
    Addr = aec_base58c:encode(account_pubkey, Pubkey),
    {ok, 200, #{<<"balance">> := Balance}} = get_balance_at_top(Addr),
    Balance.

spend_tokens(Sender, Recip, Amount, Fee, _Nonce) ->
    %% Generate a nonce.
    {ok,Use} = rpc(aec_next_nonce, pick_for_account, [Sender]),
    Params = #{sender => Sender, %aec_base58c:encode(account_pubkey, Sender),
	       recipient => Recip, %aec_base58c:encode(account_pubkey, Recip),
	       amount => Amount,
	       fee => Fee,
	       nonce => Use,
	       payload => <<"spending">>},
    {ok, UnsignedTx} = aec_spend_tx:new(Params),
    {ok,SignedTx} = rpc(aec_keys, sign, [UnsignedTx]),
    SerializedTx = aetx_sign:serialize_to_binary(SignedTx),
    %% Check that we get the correct hash.
    TxHash = aec_base58c:encode(tx_hash, aetx_sign:hash(SignedTx)),
    {ok, 200, #{<<"tx_hash">> := TxHash}} = post_tx(aec_base58c:encode(transaction, SerializedTx)),
    TxHash.

identity_contract(Config) ->
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
		 priv_key := APrivkey},
      acc_b := #{pub_key := BPubkey,
		 priv_key := BPrivkey}} = proplists:get_value(accounts, Config),
    % Get miner balance.
    {ok, 200, Btop} = get_balance_at_top(),
    {ok, 200, #{<<"pub_key">> := MinerAddress}} = get_miner_pub_key(),
    {ok, MinerPubkey} = aec_base58c:safe_decode(account_pubkey, MinerAddress),

    %% Compile contract "identity.aes"
    ContractString = aeso_test_utils:read_contract("identity"),
    BinCode = aeso_compiler:from_string(ContractString, []),
    HexCode = aeu_hex:hexstring_encode(BinCode),

    Function = <<"bid">>,
    Argument = <<"42">>,
    {ok, EncodedCallData} = aect_sophia:encode_call_data(HexCode, Function,
                                                         Argument),
    DecodedCallData = aeu_hex:hexstring_decode(EncodedCallData),

    %% Owned by Alice.
    AAddress = aec_base58c:encode(account_pubkey, APubkey),
    {ok,ANonce} = rpc(aec_next_nonce, pick_for_account, [APubkey]),
    ct:pal("ANonce ~p\n", [ANonce]),

    ValidEncoded = #{ owner => AAddress,
                      code => HexCode,
                      vm_version => 1,
                      deposit => 2,
                      amount => 1,
                      gas => 30,
                      gas_price => 1,
                      fee => 1,
		      nonce => ANonce,
                      call_data => EncodedCallData},

    ValidDecoded = maps:merge(ValidEncoded,
                              #{owner => APubkey,
                                code => BinCode,
                                call_data => DecodedCallData}),

    %% Create transaction and sign
    {ok, 200, #{<<"tx_hash">> := CtxA}} = sign_and_post_create_tx(APrivkey,
								  ValidDecoded),
    
    ct:pal("Ctx ~p\n", [CtxA]),
    
    %% Mine block.
    NodeName = proplists:get_value(node_name, Config),
    {ok, [_Cblock]} = aecore_suite_utils:mine_blocks(NodeName, 1),

    %% Mine some blocks.
    aecore_suite_utils:mine_blocks(NodeName, 2),
    {ok, 200, _} = get_tx(CtxA, json),

    %% Call the contract in another transaction.

    ContractPubkey = aect_contracts:compute_contract_pubkey(APubkey, ANonce),

    ContractPubkeyHash = aec_base58c:encode(contract_pubkey, ContractPubkey),
    
    ct:pal("Ckey ~p\n", [ContractPubkey]),
    ct:pal("Ckeyhash ~p\n", [ContractPubkeyHash]),

    %% Called by Bert.
    BAddress = aec_base58c:encode(account_pubkey, BPubkey),
    {ok,BNonce} = rpc(aec_next_nonce, pick_for_account, [BPubkey]),
    ct:pal("BNonce ~p\n", [BNonce]),

    ContractCallEncoded = #{ caller => BAddress,
                             contract => ContractPubkeyHash,
                             vm_version => 1,
                             amount => 1,
                             gas => 10,
                             gas_price => 1,
                             fee => 1,
			     nonce => BNonce,
                             call_data => EncodedCallData},

    ContractCallDecoded = maps:merge(ContractCallEncoded,
                              #{caller => BPubkey,
				contract => ContractPubkey,
                                call_data => DecodedCallData}),

    {ok, P1} = rpc(aec_tx_pool, peek, [infinity]), % empty
    ct:pal("P1 ~p\n", [P1]),
    %% Create call transaction and sign
    {ok, 200, #{<<"tx_hash">> := CtxB}} = sign_and_post_call_tx(BPrivkey,
							       ContractCallDecoded),
    ct:pal("Ctx ~p\n", [CtxB]),

    {ok, P2} = rpc(aec_tx_pool, peek, [infinity]), % not empty
    ct:pal("P2 ~p\n", [P2]),

    %% Mine a block
    aecore_suite_utils:mine_blocks(NodeName, 2),
    {ok, 200, #{<<"transaction">> := #{<<"block_hash">> := BlockHash}}} = get_tx(CtxB, json),
    %%true = BlockHash =/= <<"none">>,
    ct:pal("BlockHash ~p\n", [BlockHash]),

    ok.

dutch_auction_contract_1(Config) ->
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
		 priv_key := APrivkey},
      acc_b := #{pub_key := BPubkey,
		 priv_key := BPrivkey}} = proplists:get_value(accounts, Config),
    % Get miner balance.
    {ok, 200, Btop} = get_balance_at_top(),
    {ok, 200, #{<<"pub_key">> := MinerAddress}} = get_miner_pub_key(),
    {ok, MinerPubkey} = aec_base58c:safe_decode(account_pubkey, MinerAddress),

    %% Compile contract "dutch_auction.aes"
    ContractString = aeso_test_utils:read_contract("dutch_auction"),
    BinCode = aeso_compiler:from_string(ContractString, []),
    HexCode = aeu_hex:hexstring_encode(BinCode),

    Function = <<"init">>,
    Argument = <<"(42,500,5)">>,
    {ok, EncodedCallData} = aect_sophia:encode_call_data(HexCode, Function,
                                                         Argument),
    DecodedCallData = aeu_hex:hexstring_decode(EncodedCallData),

    %% Owned by Alice.
    AAddress = aec_base58c:encode(account_pubkey, APubkey),
    {ok,ANonce} = rpc(aec_next_nonce, pick_for_account, [APubkey]),
    ct:pal("ANonce ~p\n", [ANonce]),

    ValidEncoded = #{ owner => AAddress,
                      code => HexCode,
                      vm_version => 1,
                      deposit => 2,
                      amount => 1,
                      gas => 30,
                      gas_price => 1,
                      fee => 1,
		      nonce => ANonce,
                      call_data => EncodedCallData},

    ValidDecoded = maps:merge(ValidEncoded,
                              #{owner => APubkey,
                                code => BinCode,
                                call_data => DecodedCallData}),

    %% Create transaction and sign
    {ok, 200, #{<<"tx_hash">> := Ctx}} = sign_and_post_create_tx(APrivkey,
								 ValidDecoded),
    
    ct:pal("Ctx ~p\n", [Ctx]),

    %% Mine a block.
    NodeName = proplists:get_value(node_name, Config),
    {ok, [Cblock]} = aecore_suite_utils:mine_blocks(NodeName, 1),

    %% Mine some more blocks.
    aecore_suite_utils:mine_blocks(NodeName, 2),

    %% Call the contract in another transaction.

    ContractPubkey = aect_contracts:compute_contract_pubkey(APubkey, ANonce),

    ContractPubkeyHash = aec_base58c:encode(transaction, ContractPubkey),
    
    ct:pal("Ckey ~p\n", [ContractPubkey]),
    ct:pal("Ckeyhash ~p\n", [ContractPubkeyHash]),

    %% Called by Bert.
    BAddress = aec_base58c:encode(account_pubkey, BPubkey),
    {ok,BNonce} = rpc(aec_next_nonce, pick_for_account, [BPubkey]),
    ct:pal("BNonce ~p\n", [BNonce]),

    ContractCallEncoded = #{ caller => BAddress,
                             contract => ContractPubkeyHash,
                             vm_version => 1,
                             amount => 1,
                             gas => 10,
                             gas_price => 1,
                             fee => 1,
			     nonce => BNonce,
                             call_data => EncodedCallData},

    ContractCallDecoded = maps:merge(ContractCallEncoded,
                              #{caller => BPubkey,
				contract => ContractPubkey,
                                call_data => DecodedCallData}),

    %% Create call transaction and sign
    CallRet = sign_and_post_call_tx(BPrivkey, ContractCallDecoded),
    
    ct:pal("Callret ~p\n", [CallRet]),

    %% Mine a block
    aecore_suite_utils:mine_blocks(NodeName, 2),

    ok.

dutch_auction_contract_2(Config) ->
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
		 priv_key := APrivkey},
      acc_b := #{pub_key := BPubkey,
		 priv_key := BPrivkey}} = proplists:get_value(accounts, Config),
    % Get miner balance.
    {ok, 200, Btop} = get_balance_at_top(),
    {ok, 200, #{<<"pub_key">> := MinerAddress}} = get_miner_pub_key(),
    {ok, MinerPubkey} = aec_base58c:safe_decode(account_pubkey, MinerAddress),

    %% Compile contract "dutch_auction.aes"
    ContractString = aeso_test_utils:read_contract("dutch_auction"),
    BinCode = aeso_compiler:from_string(ContractString, []),
    HexCode = aeu_hex:hexstring_encode(BinCode),

    ct:pal("hexcode ~p\n", [HexCode]),

    %% Owned by Alice.
    AAddress = aec_base58c:encode(account_pubkey, APubkey),
    {ok,ANonce} = rpc(aec_next_nonce, pick_for_account, [APubkey]),
    ct:pal("ANonce ~p\n", [ANonce]),

    Function = <<"init">>,
    Argument = <<"(42,500,5)">>,
    {ok, EncodedCallData} = aect_sophia:encode_call_data(HexCode, Function,
                                                         Argument),
    DecodedCallData = aeu_hex:hexstring_decode(EncodedCallData),

    ValidEncoded = #{ owner => AAddress,
                      code => HexCode,
                      vm_version => 1,
                      deposit => 2,
                      amount => 1,
                      gas => 30,
                      gas_price => 1,
                      fee => 1,
		      nonce => ANonce,
                      call_data => EncodedCallData},

    ValidDecoded = maps:merge(ValidEncoded,
                              #{owner => APubkey,
                                code => BinCode,
                                call_data => DecodedCallData}),

    %% Prepare a contract_create_tx and post it.
    {ok,200,#{<<"tx">> := EncodedUnsignedContractCreateTx,
	      <<"contract_address">> := _ContractPubkey}} =
	get_contract_create(ValidEncoded),
    Ctx = sign_and_post_tx(AAddress, EncodedUnsignedContractCreateTx),

    %% Create transaction and sign
    %% {ok, 200, #{<<"tx_hash">> := Ctx}} = sign_and_post_create_tx(APrivkey,
    %% 								 ValidDecoded),
    
    ct:pal("Ctx ~p\n", [{Ctx,AAddress}]),

    %% Mine a block.
    NodeName = proplists:get_value(node_name, Config),
    {ok, [Cblock]} = aecore_suite_utils:mine_blocks(NodeName, 1),

    %% Mine some more blocks.
    aecore_suite_utils:mine_blocks(NodeName, 2),

    %% Call the contract in another transaction.

    ContractPubkey = aect_contracts:compute_contract_pubkey(APubkey, ANonce),

    ContractPubkeyHash = aec_base58c:encode(transaction, ContractPubkey),
    
    ct:pal("Ckey ~p\n", [ContractPubkey]),
    ct:pal("Ckeyhash ~p\n", [ContractPubkeyHash]),

    %% Called by Bert.
    BAddress = aec_base58c:encode(account_pubkey, BPubkey),
    {ok,BNonce} = rpc(aec_next_nonce, pick_for_account, [BPubkey]),
    ct:pal("BNonce ~p\n", [BNonce]),

    ContractCallEncoded = #{ caller => BAddress,
                             contract => ContractPubkeyHash,
                             vm_version => 1,
                             amount => 1,
                             gas => 10,
                             gas_price => 1,
                             fee => 1,
			     nonce => BNonce,
                             call_data => EncodedCallData},

    ContractCallDecoded = maps:merge(ContractCallEncoded,
                              #{caller => BPubkey,
				contract => ContractPubkey,
                                call_data => DecodedCallData}),

    %% Create call transaction and sign
    CallRet = sign_and_post_call_tx(BPrivkey, ContractCallDecoded),
    
    ct:pal("Callret ~p\n", [CallRet]),

    %% Mine a block
    aecore_suite_utils:mine_blocks(NodeName, 2),

    ok.

sign_and_post_create_tx(Privkey, Decoded) ->
    {ok,Transaction} = aect_create_tx:new(Decoded),
    SignedTrans = aetx_sign:sign(Transaction, Privkey),
    %% Add to block candiatate.
    %% aec_tx_pool:push(SignedTrans),
    SendTrans = aec_base58c:encode(transaction,
				   aetx_sign:serialize_to_binary(SignedTrans)),
    post_tx(SendTrans).

sign_and_post_call_tx(Privkey, CallDecoded) ->
    {ok,CallTrans} = aect_call_tx:new(CallDecoded),
    SignedCall = aetx_sign:sign(CallTrans, Privkey),
    %% Add to block candiatate.
    %% aec_tx_pool:push(SignedCall),
    SendCallTx = aec_base58c:encode(transaction,
    				    aetx_sign:serialize_to_binary(SignedCall)),
    post_tx(SendCallTx).

%% tests the following
%% GET contract_create_tx unsigned transaction
%% GET contract_call_tx unsigned transaction
%% due to complexity of contract_call_tx (needs a contract in the state tree)
%% both positive and negative cases are tested in this test

%%
%% Channels
%%
assert_balance(Pubkey, ExpectedBalance) ->
    Address = aec_base58c:encode(account_pubkey, Pubkey),
    {ok, 200, #{<<"balance">> := ExpectedBalance}} = get_balance_at_top(Address).

%% ============================================================
%% HTTP Requests
%% ============================================================

get_top() ->
    Host = external_address(),
    http_request(Host, get, "top", []).

get_contract_create(Data) ->
    Host = external_address(),
    http_request(Host, post, "tx/contract/create", Data).

get_contract_call(Data) ->
    Host = external_address(),
    http_request(Host, post, "tx/contract/call", Data).

get_contract_call_compute(Data) ->
    Host = external_address(),
    http_request(Host, post, "tx/contract/call/compute", Data).

get_spend(Data) ->
    Host = external_address(),
    http_request(Host, post, "tx/spend", Data).

%% get_name_preclaim(Data) ->
%%     Host = external_address(),
%%     http_request(Host, post, "tx/name/preclaim", Data).

%% get_name_claim(Data) ->
%%     Host = external_address(),
%%     http_request(Host, post, "tx/name/claim", Data).

%% get_name_update(Data) ->
%%     Host = external_address(),
%%     http_request(Host, post, "tx/name/update", Data).

%% get_name_transfer(Data) ->
%%     Host = external_address(),
%%     http_request(Host, post, "tx/name/transfer", Data).

%% get_name_revoke(Data) ->
%%     Host = external_address(),
%%     http_request(Host, post, "tx/name/revoke", Data).

%% get_channel_create(Data) ->
%%     Host = external_address(),
%%     http_request(Host, post, "tx/channel/create", Data).

%% get_channel_deposit(Data) ->
%%     Host = external_address(),
%%     http_request(Host, post, "tx/channel/deposit", Data).

%% get_channel_withdrawal(Data) ->
%%     Host = external_address(),
%%     http_request(Host, post, "tx/channel/withdrawal", Data).

%% get_channel_close_mutual(Data) ->
%%     Host = external_address(),
%%     http_request(Host, post, "tx/channel/close/mutual", Data).

%% get_channel_close_solo(Data) ->
%%     Host = external_address(),
%%     http_request(Host, post, "tx/channel/close/solo", Data).

%% get_channel_slash(Data) ->
%%     Host = external_address(),
%%     http_request(Host, post, "tx/channel/slash", Data).

%% get_channel_settle(Data) ->
%%     Host = external_address(),
%%     http_request(Host, post, "tx/channel/settle", Data).

get_block_by_height(Height, TxObjects) ->
    Params = tx_encoding_param(TxObjects),
    Host = external_address(),
    http_request(Host, get, "block/height/" ++ integer_to_list(Height), Params).

get_block_by_height(Height) ->
    Host = external_address(),
    http_request(Host, get, "block/height/" ++ integer_to_list(Height), []).

get_block_by_hash(Hash, TxObjects) ->
    Params = tx_encoding_param(TxObjects),
    Host = external_address(),
    http_request(Host, get, "block/hash/" ++ http_uri:encode(Hash), Params).

get_header_by_hash(Hash) ->
    Host = external_address(),
    http_request(Host, get, "header-by-hash", [{hash, Hash}]).

get_transactions() ->
    Host = external_address(),
    http_request(Host, get, "transactions", []).

get_tx(TxHash, TxEncoding) ->
    Params = tx_encoding_param(TxEncoding),
    Host = external_address(),
    http_request(Host, get, "tx/" ++ binary_to_list(TxHash), Params).

post_spend_tx(Recipient, Amount, Fee) ->
    post_spend_tx(Recipient, Amount, Fee, <<"foo">>).

post_spend_tx(Recipient, Amount, Fee, Payload) ->
    Host = internal_address(),
    http_request(Host, post, "spend-tx",
                 #{recipient_pubkey => aec_base58c:encode(account_pubkey,
							  Recipient),
                   amount => Amount,
                   fee => Fee,
                   payload => Payload}).

%% post_name_preclaim_tx(Commitment, Fee) ->
%%     Host = internal_address(),
%%     http_request(Host, post, "name-preclaim-tx",
%%                  #{commitment => aec_base58c:encode(commitment, Commitment),
%%                    fee        => Fee}).

%% post_name_claim_tx(Name, NameSalt, Fee) ->
%%     Host = internal_address(),
%%     http_request(Host, post, "name-claim-tx",
%%                  #{name      => Name,
%%                    name_salt => NameSalt,
%%                    fee       => Fee}).

%% post_name_update_tx(NameHash, NameTTL, Pointers, TTL, Fee) ->
%%     Host = internal_address(),
%%     http_request(Host, post, "name-update-tx",
%%                  #{name_hash => aec_base58c:encode(name, NameHash),
%%                    name_ttl  => NameTTL,
%%                    pointers  => Pointers,
%%                    ttl       => TTL,
%%                    fee       => Fee}).

%% post_name_transfer_tx(NameHash, RecipientPubKey, Fee) ->
%%     Host = internal_address(),
%%     http_request(Host, post, "name-transfer-tx",
%%                  #{name_hash        => aec_base58c:encode(name, NameHash),
%%                    recipient_pubkey => aec_base58c:encode(account_pubkey, RecipientPubKey),
%%                    fee              => Fee}).

%% post_name_revoke_tx(NameHash, Fee) ->
%%     Host = internal_address(),
%%     http_request(Host, post, "name-revoke-tx",
%%                  #{name_hash => aec_base58c:encode(name, NameHash),
%%                    fee       => Fee}).

%% get_commitment_hash(Name, Salt) ->
%%     Host = external_address(),
%%     http_request(Host, get, "commitment-hash", [{name, Name}, {salt, Salt}]).

%% get_name(Name) ->
%%     Host = external_address(),
%%     http_request(Host, get, "name", [{name, Name}]).

get_balance_at_top() ->
    {ok, 200, #{<<"pub_key">> := EncodedPubKey}} = get_miner_pub_key(),
    get_balance_at_top(EncodedPubKey).

get_balance_at_top(EncodedPubKey) ->
    get_balance(EncodedPubKey, []).

get_balance(EncodedPubKey, Params) ->
    Host = external_address(),
    http_request(Host, get, "account/" ++ binary_to_list(EncodedPubKey) ++ "/balance",
                 Params).

get_account_transactions(EncodedPubKey, Params) ->
    Host = external_address(),
    http_request(Host, get, "account/" ++ binary_to_list(EncodedPubKey) ++ "/txs",
                 Params).

%% post_block(Block) ->
%%     post_block_map(aehttp_api_parser:encode(block, Block)).

%% post_block_map(BlockMap) ->
%%     Host = external_address(),
%%     http_request(Host, post, "block", BlockMap).

post_tx(TxSerialized) ->
    Host = external_address(),
    http_request(Host, post, "tx", #{tx => TxSerialized}).

%% get_all_accounts_balances() ->
%%     Host = external_address(),
%%     http_request(Host, get, "balances", []).

get_miner_pub_key() ->
    Host = internal_address(),
    http_request(Host, get, "account/pub-key", []).

%% get_peer_pub_key() ->
%%     Host = external_address(),
%%     http_request(Host, get, "peer/key", []).

%% get_version() ->
%%     Host = external_address(),
%%     http_request(Host, get, "version", []).

%% get_info() ->
%%     Host = external_address(),
%%     http_request(Host, get, "info", []).

%% get_block_number() ->
%%     Host = internal_address(),
%%     http_request(Host, get, "block/number", []).

get_internal_block_preset(Segment, TxObjects) ->
    Params = tx_encoding_param(TxObjects),
    Host = external_address(),
    http_request(Host, get, "block/" ++ Segment, Params).

tx_encoding_param(default) -> #{};
tx_encoding_param(json) -> #{tx_encoding => <<"json">>};
tx_encoding_param(message_pack) -> #{tx_encoding => <<"message_pack">>}.

%% get_block_txs_count_by_height(Height) ->
%%     Host = internal_address(),
%%     http_request(Host, get, "block/txs/count/height/" ++ integer_to_list(Height),
%%                  []).

%% get_block_txs_count_by_hash(Hash) ->
%%     Host = internal_address(),
%%     http_request(Host, get, "block/txs/count/hash/" ++ http_uri:encode(Hash),
%%                  []).

%% get_block_txs_count_preset(Segment) ->
%%     Host = internal_address(),
%%     http_request(Host, get, "block/txs/count/" ++ Segment, []).

%% get_block_tx_by_index_height(Height, Index, TxObjects) ->
%%     Params = tx_encoding_param(TxObjects),
%%     Host = internal_address(),
%%     http_request(Host, get, "block/tx/height/" ++ integer_to_list(Height) ++
%%                                        "/" ++ integer_to_list(Index), Params).

%% get_block_tx_by_index_hash(Hash, Index, TxObjects) when is_binary(Hash) ->
%%     get_block_tx_by_index_hash(binary_to_list(Hash), Index, TxObjects);
%% get_block_tx_by_index_hash(Hash, Index, TxObjects) ->
%%     Params = tx_encoding_param(TxObjects),
%%     Host = internal_address(),
%%     http_request(Host, get, "block/tx/hash/" ++ http_uri:encode(Hash) ++
%%                                        "/" ++ integer_to_list(Index), Params).

%% get_block_tx_by_index_latest(Index, TxObjects) ->
%%     Params = tx_encoding_param(TxObjects),
%%     Host = internal_address(),
%%     http_request(Host, get, "block/tx/latest/" ++ integer_to_list(Index), Params).

%% get_block_txs_list_by_height(From, To, TxObjects, TxTypes) ->
%%     Params0 = tx_encoding_param(TxObjects),
%%     Filter = make_tx_types_filter(TxTypes),
%%     Params = maps:merge(Params0, maps:merge(Filter, #{from => From, to => To})),
%%     Host = internal_address(),
%%     http_request(Host, get, "block/txs/list/height", Params).

%% get_block_txs_list_by_hash(From, To, TxObjects, TxTypes) ->
%%     Params0 = tx_encoding_param(TxObjects),
%%     Filter = make_tx_types_filter(TxTypes),
%%     Params = maps:merge(Params0, maps:merge(Filter, #{from => From, to => To})),
%%     Host = internal_address(),
%%     http_request(Host, get, "block/txs/list/hash", Params).

%% make_tx_types_filter(Filter) ->
%%     Includes = maps:get(include, Filter, []),
%%     Excludes = maps:get(exclude, Filter, []),
%%     Encode =
%%         fun(_, [], Res) -> Res;
%%         (Key, TypesBin, Res) ->
%%             Types = lists:map(fun binary_to_list/1, TypesBin),
%%             T = list_to_binary(lists:join(",", Types)),
%%             maps:put(Key, T, Res)
%%         end,
%%     R0 = Encode(tx_types, Includes, #{}),
%%     R = Encode(exclude_tx_types, Excludes, R0),
%%     R.

%% get_list_oracles(Max) ->
%%     get_list_oracles(undefined, Max).

%% get_list_oracles(From, Max) ->
%%     Host = internal_address(),
%%     Params0 = #{ max => Max },
%%     Params = case From of undefined -> Params0; _ -> Params0#{ from => From } end,
%%     {ok, 200, Oracles} = http_request(Host, get, "oracles", Params),
%%     Oracles.

%% get_list_oracle_queries(Oracle, Max) ->
%%     get_list_oracle_queries(Oracle, undefined, Max).

%% get_list_oracle_queries(Oracle, From, Max) ->
%%     Host = internal_address(),
%%     Params0 = #{ max => Max, oracle_pub_key => aec_base58c:encode(oracle_pubkey, Oracle) },
%%     Params = case From of undefined -> Params0; _ -> Params0#{ from => From } end,
%%     {ok, 200, Queries} = http_request(Host, get, "oracle-questions", Params),
%%     Queries.

%% get_peers() ->
%%     Host = internal_address(),
%%     http_request(Host, get, "debug/peers", []).


%% ============================================================
%% private functions
%% ============================================================
rpc(Mod, Fun, Args) ->
    rpc(?NODE, Mod, Fun, Args).

rpc(Node, Mod, Fun, Args) ->
    rpc:call(aecore_suite_utils:node_name(Node), Mod, Fun, Args, 5000).

external_address() ->
    Port = rpc(aeu_env, user_config_or_env,
              [ [<<"http">>, <<"external">>, <<"port">>],
                aehttp, [external, port], 8043]),
    "http://127.0.0.1:" ++ integer_to_list(Port).     % good enough for requests

internal_address() ->
    Port = rpc(aeu_env, user_config_or_env,
              [ [<<"http">>, <<"internal">>, <<"port">>],
                aehttp, [internal, port], 8143]),
    "http://127.0.0.1:" ++ integer_to_list(Port).

ws_host_and_port() ->
    Port = rpc(aeu_env, user_config_or_env,
              [ [<<"websocket">>, <<"internal">>, <<"port">>],
                aehttp, [internal, websocket, port], 8144]),
    {"127.0.0.1", Port}.

channel_ws_host_and_port() ->
    Port = rpc(aeu_env, user_config_or_env,
              [ [<<"websocket">>, <<"channel">>, <<"port">>],
                aehttp, [channel, websocket, port], 8045]),
    {"localhost", Port}.

http_request(Host, get, Path, Params) ->
    URL = binary_to_list(
            iolist_to_binary([Host, "/v2/", Path, encode_get_params(Params)])),
    ct:log("GET ~p", [URL]),
    R = httpc_request(get, {URL, []}, [], []),
    process_http_return(R);
http_request(Host, post, Path, Params) ->
    URL = binary_to_list(iolist_to_binary([Host, "/v2/", Path])),
    {Type, Body} = case Params of
                       Map when is_map(Map) ->
                           %% JSON-encoded
                           {"application/json", jsx:encode(Params)};
                       [] ->
                           {"application/x-www-form-urlencoded",
                            http_uri:encode(Path)}
                   end,
    %% lager:debug("Type = ~p; Body = ~p", [Type, Body]),
    ct:log("POST ~p, type ~p, Body ~p", [URL, Type, Body]),
    R = httpc_request(post, {URL, [], Type, Body}, [], []),
    process_http_return(R).

httpc_request(Method, Request, HTTPOptions, Options) ->
    httpc_request(Method, Request, HTTPOptions, Options, test_browser).

httpc_request(Method, Request, HTTPOptions, Options, Profile) ->
    {ok, Pid} = inets:start(httpc, [{profile, Profile}], stand_alone),
    Response = httpc:request(Method, Request, HTTPOptions, Options, Pid),
    ok = gen_server:stop(Pid, normal, infinity),
    Response.

encode_get_params(#{} = Ps) ->
    encode_get_params(maps:to_list(Ps));
encode_get_params([{K,V}|T]) ->
    ["?", [str(K),"=",uenc(V)
           | [["&", str(K1), "=", uenc(V1)]
              || {K1, V1} <- T]]];
encode_get_params([]) ->
    [].

str(A) when is_atom(A) ->
    str(atom_to_binary(A, utf8));
str(S) when is_list(S); is_binary(S) ->
    S.

uenc(I) when is_integer(I) ->
    uenc(integer_to_list(I));
uenc(V) ->
    http_uri:encode(V).

process_http_return(R) ->
    case R of
        {ok, {{_, ReturnCode, _State}, _Head, Body}} ->
            try
                ct:log("Return code ~p, Body ~p", [ReturnCode, Body]),
                Result =
                    case iolist_to_binary(Body) of
                        <<>> ->
                            #{};
                        BodyB ->
                            jsx:decode(BodyB, [return_maps])
                    end,
                {ok, ReturnCode, Result}
            catch
                error:E ->
                    {error, {parse_error, [E, erlang:get_stacktrace()]}}
            end;
        {error, _} = Error ->
            Error
    end.

header_to_endpoint_top(Header) ->
    {ok, Hash} = aec_headers:hash_header(Header),
    maps:put(<<"hash">>, aec_base58c:encode(block_hash, Hash),
             aehttp_api_parser:encode(header, Header)).

block_to_endpoint_gossip_map(Block) ->
    aehttp_api_parser:encode(block, Block).

block_to_endpoint_map(Block) ->
    block_to_endpoint_map(Block, #{tx_encoding => message_pack}).

block_to_endpoint_map(Block, Options) ->
    Encoding = maps:get(tx_encoding, Options, message_pack),
    BMap = aehttp_api_parser:encode_client_readable_block(Block, Encoding),
    Expected = aehttp_logic:cleanup_genesis(BMap),

    %% Validate that all transactions have the correct block height and hash
    ExpectedTxs = maps:get(<<"transactions">>, Expected, []),
    case ExpectedTxs =:= [] of
        true -> 0 = aec_blocks:height(Block); % only allowed for gen block
        false -> pass
    end,
    BlockHeight = aec_blocks:height(Block),
    {ok, BlockHash} = aec_blocks:hash_internal_representation(Block),
    lists:foreach(
        fun({EncodedTx, SignedTx}) ->
            #{block_hash := TxBlockHash,
              block_height := TxBlockHeight,
              hash := Hash} =
                  aetx_sign:meta_data_from_client_serialized(Encoding, EncodedTx),
            {BlockHeight, TxBlockHeight} = {TxBlockHeight, BlockHeight},
            {BlockHash, TxBlockHash} = {TxBlockHash, BlockHash},
            TxHash = aetx_sign:hash(SignedTx),
            {Hash, TxHash} = {TxHash, Hash}
        end,
        lists:zip(ExpectedTxs, aec_blocks:txs(Block))),
    Expected.

random_hash() ->
    HList =
        lists:map(
            fun(_) -> rand:uniform(255) end,
            lists:seq(1, 65)),
    list_to_binary(HList).

prepare_for_spending(BlocksToMine) ->
    aecore_suite_utils:mine_blocks(aecore_suite_utils:node_name(?NODE),
                                   BlocksToMine),
    {ok, []} = rpc(aec_tx_pool, peek, [infinity]), % empty
    {ok, 200, _} = get_balance_at_top(), % account present
    {ok, PubKey} = rpc(aec_keys, pubkey, []),
    {ok, Nonce} = rpc(aec_next_nonce, pick_for_account, [PubKey]),
    {PubKey, Nonce}.

-spec block_hash_by_height(integer()) -> string().
block_hash_by_height(Height) ->
    {ok, B} = rpc(aec_chain, get_block_by_height, [Height]),
    {ok, HBin} = aec_blocks:hash_internal_representation(B),
    Hash = binary_to_list(aec_base58c:encode(block_hash, HBin)),
    {ok, Hash}.

-spec get_pending_block() -> {error, no_candidate}
                           | {error, not_mining}
                           | {ok, term()}.
get_pending_block() ->
    aec_test_utils:exec_with_timeout(
        fun TryGetting() ->
            case rpc(aec_conductor, get_block_candidate, []) of
                {ok, OK} -> OK;
                {error, not_mining} = Err->
                    Err;
                {error, miner_starting} ->
                    timer:sleep(10),
                    TryGetting()
            end
        end,
        10000).

add_spend_txs() ->
    MineReward = rpc(aec_governance, block_mine_reward, []),
    MinFee = rpc(aec_governance, minimum_tx_fee, []),
    %% For now. Mining is severly slowed down by having too many Tx:s in
    %% the tx pool
    MaxSpendTxsInBlock = 20,
    MinimalAmount = 1,
    MaxTxs = min(MineReward div (MinimalAmount + MinFee), % enough tokens
                 MaxSpendTxsInBlock), % so it can fit in one block
    true = MaxTxs > 0,
    TxsCnt =
        case MaxTxs of
            1 -> 1;
            _ -> rand:uniform(MaxTxs - 1) + 1
        end,
    ct:log("adding ~p spend txs", [TxsCnt]),
    Txs =
        lists:map(
            fun(_) ->
                #{recipient => random_hash(), amount => MinimalAmount, fee => MinFee}
            end,
            lists:seq(0, TxsCnt -1)),
    populate_block(#{spend_txs => Txs}),
    TxsCnt.

populate_block(Txs) ->
    lists:foreach(
        fun(#{recipient := R, amount := A, fee := F}) ->
            {ok, 200, _} = post_spend_tx(R, A, F)
        end,
        maps:get(spend_txs, Txs, [])),
    ok.

give_tokens(RecipientPubkey, Amount) ->
    MineReward = rpc(aec_governance, block_mine_reward, []),
    MinFee = rpc(aec_governance, minimum_tx_fee, []),
    NeededBlocks = ((Amount + MinFee)  div MineReward) + 1,
    aecore_suite_utils:mine_blocks(aecore_suite_utils:node_name(?NODE),
                                   NeededBlocks),
    SpendData = #{recipient => RecipientPubkey,
                  amount => Amount,
                  fee => MinFee},
    populate_block(#{spend_txs => [SpendData]}),
    aecore_suite_utils:mine_blocks(aecore_suite_utils:node_name(?NODE), 2),
    ok.

%% %% we don't have any guarantee for the ordering of the txs in the block
%% equal_block_maps(MapL0, MapR0) ->
%%     Pop =
%%       fun(Key, Map0, Default) ->
%%           Val = maps:get(Key, Map0, Default),
%%           Map1 = maps:remove(Key, Map0),
%%           {Val, Map1}
%%       end,
%%     {TxsL, MapL1} = Pop(<<"transactions">>, MapL0, []),
%%     {TxsR, MapR1} = Pop(<<"transactions">>, MapR0, []),
%%     SortedTxsL = lists:sort(TxsL),
%%     SortedTxsR = lists:sort(TxsR),
%%     ct:log("Sorted txs left: ~p", [SortedTxsL]),
%%     ct:log("Sorted txs right: ~p", [SortedTxsR]),
%%     MapL1 =:= MapR1 andalso SortedTxsL =:= SortedTxsR.

%% minimal_fee_and_blocks_to_mine(Amount, ChecksCnt) ->
%%     Fee = rpc(aec_governance, minimum_tx_fee, []),
%%     MineReward = rpc(aec_governance, block_mine_reward, []),
%%     TokensRequired = (Amount + Fee) * ChecksCnt,
%%     BlocksToMine = trunc(math:ceil(TokensRequired / MineReward)),
%%     {BlocksToMine, Fee}.

%% ws_start_link() ->
%%     {Host, Port} = ws_host_and_port(),
%%     ?WS:start_link(Host, Port).

%% channel_ws_start(Role, Opts) ->
%%     {Host, Port} = channel_ws_host_and_port(),
%%     ?WS:start_channel(Host, Port, Role, Opts).

%% open_websockets_count() ->
%%     QueueName = ws_handlers_queue,
%%     % ensure queue exsits
%%     true = undefined =/= rpc(jobs, queue_info, [QueueName]),
%%     length([1 || {_, QName} <- rpc(jobs, info, [monitors]),
%%                  QName =:= QueueName]).

sign_and_post_tx(AccountPubKey, EncodedUnsignedTx) ->
    {ok, SerializedUnsignedTx} = aec_base58c:safe_decode(transaction, EncodedUnsignedTx),
    UnsignedTx = aetx:deserialize_from_binary(SerializedUnsignedTx),
    {ok, SignedTx} = rpc(aec_keys, sign, [UnsignedTx]),
    SerializedTx = aetx_sign:serialize_to_binary(SignedTx),
    #{<<"hash">> := TxHash} = aetx_sign:serialize_for_client_pending(json, SignedTx),
    {ok, 200, #{<<"tx_hash">> := TxHash}} = post_tx(aec_base58c:encode(transaction, SerializedTx)),
    %% Check tx is in mempool.
    %% Fun = fun() ->
    %%               tx_in_mempool_for_account(AccountPubKey, TxHash)
    %%       end,
    %% {ok, true} = aec_test_utils:wait_for_it_or_timeout(Fun, true, 5000),
    TxHash.

tx_in_mempool_for_account(AccountPubKey, TxHash) ->
    {ok, 200, #{<<"transactions">> := Txs}} =
        get_account_transactions(AccountPubKey, tx_encoding_param(json)),
    lists:any(fun(#{<<"block_hash">> := <<"none">>, <<"hash">> := TxHash1}) ->
                      TxHash1 =:= TxHash;
                 (_) ->
                      false
              end, Txs).

%% make_params(L) ->
%%     make_params(L, []).

%% make_params([], Accum) ->
%%     maps:from_list(Accum);
%% make_params([H | T], Accum) when is_map(H) ->
%%     make_params(T, maps:to_list(H) ++ Accum);
%% make_params([{K, V} | T], Accum) ->
%%     make_params(T, [{K, V} | Accum]).

generate_key_pair() ->
    #{ public := Pubkey, secret := Privkey } = enacl:sign_keypair(),
    {Pubkey, Privkey}.
