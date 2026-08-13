.PHONY: build test audit testmd gas sizes cov fork fork-test deploy fmt

build:
	forge build

test:
	forge test -vvv

# Regression suite for every finding carried over from the LUVLocker audit,
# plus the properties that make an ownerless locker safe. Never delete these.
audit:
	forge test --match-test 'test_A1_|test_A2_|test_A3_|test_A4A5_' -vvv
	forge test --match-test 'FeeOnTransfer|TwoFeeTokenLockersBothExit|Reentrant' -vvv
	forge test --match-test 'Sweep|Consent|Replay|AnotherChain' -vvv

# Verify test.md's green checkmarks against a live run. Fails on drift.
testmd:
	python3 ../scripts/check_test_md.py $(notdir $(CURDIR))

gas:
	forge test --gas-report

sizes:
	forge build --sizes

cov:
	forge coverage --report lcov

fork:
	forge script script/deploy.s.sol:Deploy --rpc-url mainnet

# The mainnet-fork rehearsal: lock the REAL Uniswap V2 LUV/WETH pair token, held by the real
# treasury, at whatever balance the chain reports right now. Needs network; skipped by the
# default suite so an offline build can never fail on it. ETH_RPC_URL overrides the public
# node; FORK_BLOCK pins a height (archive node required once it ages out).
fork-test:
	FOUNDRY_PROFILE=fork FORK_TEST=1 forge test --match-path test/liquidity_locker_fork.t.sol -vv

deploy:
	forge script script/deploy.s.sol:Deploy --rpc-url mainnet --broadcast --verify --slow

fmt:
	forge fmt
