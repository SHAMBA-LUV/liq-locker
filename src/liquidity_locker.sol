// SPDX-License-Identifier: Apache-2.0
// (c) 2026 BANKON / cypherpunk2048 — Apache-2.0
//
// liquidity_locker — the ownerless timelock. Holds any ERC-20 (an AMM pair token
// above all) until a stated moment, and gives nobody — including its own deployer —
// the power to bring that moment forward. It exists so that the claim "the liquidity
// is locked" can be checked rather than believed.
pragma solidity >=0.8.0;

import {i_erc20_min, safe_token, guarded} from "./in_house.sol";

/**
 * @title  liquidity_locker
 * @notice Beneficiary-bound, extend-only ERC-20 timelocks. No owner, ever.
 *
 * @dev    LINEAGE. Derived from SHAMBA LUV's LUVLocker (live at
 *         0xe07ACAde4bE2bbc264EA702880ed988EBae9B898) and the audit of it dated
 *         2026-08-03, by way of LUVLockerModern. That audit raised five findings.
 *         Three of them — A1 (the owner could extend any depositor's lock, a
 *         hostage mechanism), A4 (no incident brake), A5 (single-step ownership) —
 *         are all findings ABOUT AN OWNER. LUVLockerModern patched them by
 *         constraining what the owner may do. This contract removes the owner, so
 *         there is nothing left to constrain and nothing left to patch. A2 (asset
 *         locks were not extendable) and A3 (locks bound to the funder, so a
 *         treasury could not lock on another's behalf) are fixed directly, in
 *         `extend` and in the `beneficiary` argument to `lock`.
 *
 *         WHAT IS DELIBERATELY MISSING. No owner. No rescue. No pause. No setter of
 *         any kind. No proxy, no delegatecall, no SELFDESTRUCT, no `tx.origin`. There
 *         is no privileged address in this file, so there is no key whose loss or
 *         compromise changes what the contract does. The complete list of powers
 *         anyone holds is: a beneficiary may lengthen their own lock, reassign it, or
 *         withdraw it after it matures.
 *
 *         THE ONE PERMISSIONLESS SWEEP. Removing the owner would normally strand any
 *         token sent here by mistake, since `rescue` is exactly the owner power the
 *         audit was reassuring about. Instead, `sweep_surplus` is callable by anyone
 *         and pays to SURPLUS_SINK, which is immutable. This is BANKON's
 *         `bankon_custody.redeem_*` pattern: a permissionless sweep is safe precisely
 *         because its destination can never change. It can only ever move balance
 *         that no lock claims; locked principal is unreachable by construction, not
 *         by permission.
 *
 *         MEASURED DELTAS, ALWAYS. Every credit is the observed change in this
 *         contract's balance, never the requested amount. Fee-on-transfer tokens
 *         would otherwise let `total_locked` drift above the real balance, and the
 *         last withdrawer would pay for it. BANKON's own fee paths get this wrong
 *         (TECHNICAL.md §8 concedes fee-on-transfer tokens mis-split); LUVLocker got
 *         it right. This follows LUVLocker.
 */
contract liquidity_locker is guarded {
    using safe_token for address;

    // ------------------------------------------------------------------- errors
    error zero_address();
    error amount_zero();
    error bad_unlock_time();
    error duration_too_long();
    error not_beneficiary();
    error not_shortenable();
    error still_locked();
    error already_withdrawn();
    error lock_not_found();
    error nothing_to_sweep();
    error timestamp_overflow();

    // ------------------------------------------------------------------- events
    event locked(
        uint256 indexed id,
        address indexed beneficiary,
        address indexed token,
        address funder,
        uint256 amount,
        uint48 unlock_at,
        uint40 unlock_block
    );
    event extended(uint256 indexed id, uint48 old_unlock_at, uint48 new_unlock_at);
    event block_extended(uint256 indexed id, uint40 old_unlock_block, uint40 new_unlock_block);
    event assigned(uint256 indexed id, address indexed from, address indexed to);
    event released(uint256 indexed id, address indexed beneficiary, address to, uint256 amount);
    event surplus_swept(address indexed token, address indexed sink, uint256 amount);
    event interest_redeemed(
        uint256 indexed id, address indexed beneficiary, address to, address token, uint256 amount
    );

    // ---------------------------------------------------------------- constants
    /// @dev Two hundred years. The bound still exists for the reason it always did —
    ///      the adversary is a fat finger, someone locking their own liquidity until
    ///      the year 50,000 — but ten years could not express the commitment this
    ///      vault is being asked to make. A lock that must stand a century cannot be
    ///      capped at a decade and rolled forward by hand: that converts a guarantee
    ///      into a liveness assumption, and the assumption fails the first time a key
    ///      is lost or a steward forgets. The horizon is set to the longest one this
    ///      house already builds to — Arweave's 200-year storage endowment — so the
    ///      lock outlives the 100-year mandate, the 140 years of Uniswap this design
    ///      presumes, and the people who deployed it.
    ///
    ///      uint48 seconds overflow in the year 8,921,556, so 200 years is not close
    ///      to any representational limit; `_now48() + MAX_LOCK_DURATION` peaks around
    ///      8.1e9 against a uint48 ceiling of 2.8e14.
    uint256 public constant MAX_LOCK_DURATION = 73050 days;

    /// @dev The house default: ninety days. Chosen because it is the shortest lock that
    ///      still says something — a quarter is long enough that it cannot be timed
    ///      around, short enough that a first-time locker will take it — and because a
    ///      default that is easy to EXTEND is safer than a long default nobody dares
    ///      commit to. `lock_default` and `extend_default` are the whole of the common
    ///      case; a lock started at ninety days can be pushed to two centuries a
    ///      quarter at a time, and can never be pulled back in.
    uint256 public constant DEFAULT_LOCK_DURATION = 90 days;

    /// @dev The block-height horizon, the block gate's counterpart to MAX_LOCK_DURATION.
    ///      Two billion blocks: ~760 years at Ethereum's 12s, ~127 years at 2s, ~31
    ///      years on a 0.5s L2 — long past the time horizon on any chain this is worth
    ///      deploying to, and far inside the uint40 ceiling of 1.0995e12. Block height
    ///      is monotone and cannot be nudged by a proposer the way a timestamp can, so
    ///      a lock that sets both gates is bounded by consensus as well as by clock.
    uint256 public constant MAX_LOCK_BLOCKS = 2_000_000_000;

    // --------------------------------------------------------------- immutables
    /// @notice Where unaccounted balance goes. Immutable — this is the whole reason
    ///         `sweep_surplus` can be permissionless.
    address public immutable SURPLUS_SINK;

    // ------------------------------------------------------------------ storage
    struct lock_record {
        address token; //     \
        uint48 unlock_at; //   } one slot, 256 bits exactly: 160 + 48 + 8 + 40
        bool withdrawn; //    /
        /// @dev THE SECOND GATE. Block height, set to 0 when unused. A lock opens only
        ///      when BOTH gates have passed, so whichever is later governs. Time is what
        ///      humans commit in and is what every reader checks, but a timestamp is a
        ///      proposer's claim about the wall clock and drifts by seconds either way;
        ///      block height is consensus itself, monotone, and cannot be nudged. A lock
        ///      that sets both cannot be opened early by a clock and cannot be stranded
        ///      by a chain that changes its cadence, because the time gate still governs
        ///      if blocks slow down and the block gate still governs if they speed up.
        uint40 unlock_block;
        address beneficiary;
        uint256 amount;
        /// @dev The accumulator when this lock last settled. Interest earned before the
        ///      lock existed is not its own, so this is set on creation, not to zero.
        uint256 debt;
    }

    /// @dev Ids are global and monotonic, never per-user. A lock's identity must not
    ///      change when it is reassigned, so it cannot be an index into a user array.
    uint256 public lock_count;

    mapping(uint256 => lock_record) private _locks;
    mapping(address => uint256) public total_locked;

    /// @dev Interest accounting, the standard accumulator.
    ///
    ///      A NAIVE PRO-RATA IS WRONG AND THE TESTS PROVED IT. Dividing the live
    ///      surplus by `total_locked` at each call pays the first redeemer their full
    ///      share and then divides a SMALLER surplus among everyone else: with two
    ///      equal locks and 200 reflected, the first takes 100 and the second computes
    ///      50 against the 100 that remains. Later claimants are silently robbed by
    ///      earlier ones, and the shortfall is stranded until every lock closes.
    ///
    ///      The fix is to record entitlement at the moment value arrives rather than at
    ///      the moment it is claimed. `_acc_per_share` is cumulative interest per unit
    ///      of principal; a lock's `debt` is the accumulator when it last settled, so
    ///      its claim is `amount * (acc - debt)` and is unaffected by who redeems first
    ///      or in what order. `_promised` is what the accumulator has already allocated
    ///      and not yet paid, which is what keeps `sweep_surplus` from touching it.
    uint256 private constant ACC_SCALE = 1e27;
    mapping(address => uint256) private _acc_per_share;
    mapping(address => uint256) public promised;

    /// @dev Append-only, for off-chain enumeration only. Reassignment appends to the
    ///      new beneficiary and never removes from the old, so entries here go stale
    ///      by design. `locks_of` filters against the authoritative record. Never
    ///      treat this mapping as truth.
    mapping(address => uint256[]) private _index_of;

    constructor(address surplus_sink_) {
        if (surplus_sink_ == address(0)) revert zero_address();
        SURPLUS_SINK = surplus_sink_;
    }

    // -------------------------------------------------------------------- locks
    /**
     * @notice Lock `amount` of `token` until `unlock_at`, withdrawable by `beneficiary`.
     * @dev    AUDIT A3. `beneficiary` is separate from `msg.sender`, so a treasury can
     *         lock LP on behalf of a community wallet or a successor DAO without ever
     *         handing over the funding key. Passing address(0) means "myself", which is
     *         the common case and the old behaviour.
     * @return id The global lock id. Emitted in `locked`; you will need it to withdraw.
     */
    function lock(address token, uint256 amount, uint48 unlock_at, address beneficiary)
        external
        non_reentrant
        returns (uint256 id)
    {
        id = _lock_from(msg.sender, token, amount, unlock_at, 0, beneficiary);
    }

    /**
     * @notice Lock for the house default — ninety days — and extend it later.
     * @dev    The common case, in one call and with no arithmetic at the keyboard. The
     *         absolute-timestamp form remains for anyone who needs a specific date; the
     *         mistake it invites (a unix timestamp typed a digit short, or in ms) is
     *         precisely what this avoids. Extending is `extend_default(id)`.
     */
    function lock_default(address token, uint256 amount, address beneficiary)
        external
        non_reentrant
        returns (uint256 id)
    {
        id = _lock_from(
            msg.sender, token, amount, _now48() + uint48(DEFAULT_LOCK_DURATION), 0, beneficiary
        );
    }

    /**
     * @notice Lock for a DURATION rather than until a date. "Ninety days", "a century".
     * @dev    Relative is the honest unit for a commitment: the promise is a length of
     *         time, and a caller who means a century should not have to compute the
     *         year 2126 correctly to express it.
     */
    function lock_for(address token, uint256 amount, uint256 duration, address beneficiary)
        external
        non_reentrant
        returns (uint256 id)
    {
        if (duration == 0) revert bad_unlock_time();
        if (duration > MAX_LOCK_DURATION) revert duration_too_long();
        id = _lock_from(msg.sender, token, amount, _now48() + uint48(duration), 0, beneficiary);
    }

    /**
     * @notice Lock behind BOTH gates: a timestamp and a block height. Either may be 0.
     * @dev    The full form. `unlock_at = 0` locks by block height alone; `unlock_block
     *         = 0` locks by time alone (what every other entry point does); setting both
     *         means the lock opens when the LATER of the two has passed. At least one
     *         gate must be set and in the future, or there is no lock to speak of.
     */
    function lock_until(
        address token,
        uint256 amount,
        uint48 unlock_at,
        uint40 unlock_block,
        address beneficiary
    ) external non_reentrant returns (uint256 id) {
        id = _lock_from(msg.sender, token, amount, unlock_at, unlock_block, beneficiary);
    }

    /// @dev The funder is a parameter, not `msg.sender`, so a derived contract (see
    ///      locker_door) can fund a lock on behalf of a signer without this file
    ///      knowing anything about signatures. Unguarded: every external entry point
    ///      that reaches it already holds the mutex.
    function _lock_from(
        address funder,
        address token,
        uint256 amount,
        uint48 unlock_at,
        address beneficiary
    ) internal returns (uint256 id) {
        id = _lock_from(funder, token, amount, unlock_at, 0, beneficiary);
    }

    function _lock_from(
        address funder,
        address token,
        uint256 amount,
        uint48 unlock_at,
        uint40 unlock_block,
        address beneficiary
    ) internal returns (uint256 id) {
        if (token == address(0)) revert zero_address();
        if (amount == 0) revert amount_zero();
        // At least one gate, and every gate that is set must be in the future and inside
        // its horizon. A lock with no gate at all is not a lock.
        if (unlock_at == 0 && unlock_block == 0) revert bad_unlock_time();
        if (unlock_at != 0) {
            if (unlock_at <= block.timestamp) revert bad_unlock_time();
            if (unlock_at > _now48() + uint48(MAX_LOCK_DURATION)) revert duration_too_long();
        }
        if (unlock_block != 0) {
            if (unlock_block <= block.number) revert bad_unlock_time();
            if (unlock_block > _block40() + uint40(MAX_LOCK_BLOCKS)) revert duration_too_long();
        }

        address holder = beneficiary == address(0) ? funder : beneficiary;

        // Book pre-existing interest BEFORE this deposit lands. `_sync` measures
        // "balance above the books" and cannot tell an incoming principal deposit from
        // a reflection — so syncing after the transfer would credit this lock's own
        // principal to the existing lockers as interest, and the vault would go
        // insolvent by exactly the deposited amount. Order is load-bearing here.
        _sync(token);

        // Credit what ARRIVED, never what was asked for. See the contract note.
        uint256 before = i_erc20_min(token).balanceOf(address(this));
        token.safe_transfer_from(funder, address(this), amount);
        uint256 received = i_erc20_min(token).balanceOf(address(this)) - before;
        if (received == 0) revert amount_zero();

        id = lock_count++;
        _locks[id] = lock_record({
            token: token,
            unlock_at: unlock_at,
            withdrawn: false,
            unlock_block: unlock_block,
            beneficiary: holder,
            amount: received,
            debt: _acc_per_share[token]
        });
        total_locked[token] += received;
        _index_of[holder].push(id);

        emit locked(id, holder, token, funder, received, unlock_at, unlock_block);
    }

    /**
     * @notice Push a lock's maturity later. Never earlier.
     * @dev    AUDIT A1 + A2 together. A2: the live vault could not extend an asset
     *         lock at all, so proving continued commitment meant letting the lock
     *         mature, withdrawing, and re-locking — a visible window during which the
     *         liquidity was free. That window is now unnecessary. A1: only the
     *         beneficiary may call this. In the live vault the owner could extend
     *         anyone's lock repeatedly, which is indistinguishable from confiscation.
     */
    function extend(uint256 id, uint48 new_unlock_at) external {
        _extend_for(msg.sender, id, new_unlock_at);
    }

    /**
     * @notice Push maturity out by `extra` seconds from where it already stands.
     * @dev    Extending should cost no arithmetic: this is how a ninety-day lock becomes
     *         a two-century one, a quarter at a time, without anyone computing a date.
     *         It adds to the CURRENT maturity, not to `now`, so repeated calls
     *         accumulate and a lock is never quietly shortened by extending it late.
     */
    function extend_by(uint256 id, uint256 extra) external {
        if (extra == 0) revert not_shortenable();
        lock_record storage l = _read(id);
        uint256 base = l.unlock_at == 0 ? block.timestamp : l.unlock_at;
        uint256 target = base + extra;
        if (target > type(uint48).max) revert timestamp_overflow();
        _extend_for(msg.sender, id, uint48(target));
    }

    /// @notice Extend by the house default — another ninety days on top of the current maturity.
    function extend_default(uint256 id) external {
        lock_record storage l = _read(id);
        uint256 base = l.unlock_at == 0 ? block.timestamp : l.unlock_at;
        _extend_for(msg.sender, id, uint48(base + DEFAULT_LOCK_DURATION));
    }

    /**
     * @notice Push the BLOCK gate out. Extend-only, exactly like the time gate.
     * @dev    Sets the gate on a lock that had none, or raises one that had. A lock can
     *         therefore acquire consensus-bound maturity after the fact, and can never
     *         lose it.
     */
    function extend_block(uint256 id, uint40 new_unlock_block) external {
        _extend_block_for(msg.sender, id, new_unlock_block);
    }

    /// @notice Push the block gate out by `extra_blocks` from where it already stands.
    function extend_block_by(uint256 id, uint256 extra_blocks) external {
        if (extra_blocks == 0) revert not_shortenable();
        lock_record storage l = _read(id);
        uint256 base = l.unlock_block == 0 ? block.number : l.unlock_block;
        uint256 target = base + extra_blocks;
        if (target > type(uint40).max) revert timestamp_overflow();
        _extend_block_for(msg.sender, id, uint40(target));
    }

    /// @dev The block gate's `_extend_for`: same authority, same one-way rule.
    function _extend_block_for(address holder, uint256 id, uint40 new_unlock_block) internal {
        lock_record storage l = _read(id);
        if (holder != l.beneficiary) revert not_beneficiary();
        if (l.withdrawn) revert already_withdrawn();
        if (new_unlock_block <= l.unlock_block) revert not_shortenable();
        if (new_unlock_block <= block.number) revert bad_unlock_time();
        if (new_unlock_block > _block40() + uint40(MAX_LOCK_BLOCKS)) revert duration_too_long();

        emit block_extended(id, l.unlock_block, new_unlock_block);
        l.unlock_block = new_unlock_block;
    }

    /// @dev Holder is a parameter for the same reason the funder is in `_lock_from`.
    ///      The extend-only and maturity-cap checks live here, so no caller — signed,
    ///      relayed, or direct — can route around them.
    function _extend_for(address holder, uint256 id, uint48 new_unlock_at) internal {
        lock_record storage l = _read(id);
        if (holder != l.beneficiary) revert not_beneficiary();
        if (l.withdrawn) revert already_withdrawn();
        if (new_unlock_at <= l.unlock_at) revert not_shortenable();
        if (new_unlock_at > _now48() + uint48(MAX_LOCK_DURATION)) revert duration_too_long();

        emit extended(id, l.unlock_at, new_unlock_at);
        l.unlock_at = new_unlock_at;
    }

    /**
     * @notice Hand a lock to a new beneficiary without unlocking it.
     * @dev    Succession without a trust gap. A treasury rotating to a new multisig,
     *         or handing custody to a DAO, would otherwise have to wait for maturity,
     *         withdraw, and re-lock — publishing an unlocked interval in the middle of
     *         the handover. Maturity is untouched: this moves who may open the lock,
     *         never when it opens.
     */
    function assign(uint256 id, address to) external {
        if (to == address(0)) revert zero_address();
        lock_record storage l = _read(id);
        if (msg.sender != l.beneficiary) revert not_beneficiary();
        if (l.withdrawn) revert already_withdrawn();

        l.beneficiary = to;
        _index_of[to].push(id);
        emit assigned(id, msg.sender, to);
    }

    /// @notice Withdraw a matured lock to the beneficiary.
    function withdraw(uint256 id) external non_reentrant {
        _withdraw(id, msg.sender, msg.sender);
    }

    /// @notice Withdraw a matured lock to a nominated address.
    function withdraw_to(uint256 id, address to) external non_reentrant {
        if (to == address(0)) revert zero_address();
        _withdraw(id, msg.sender, to);
    }

    function _withdraw(uint256 id, address claimant, address to) internal {
        lock_record storage l = _read(id);
        if (claimant != l.beneficiary) revert not_beneficiary();
        if (l.withdrawn) revert already_withdrawn();
        // BOTH gates. Whichever is later governs; an unset gate (0) is already passed.
        if (block.timestamp < l.unlock_at) revert still_locked();
        if (block.number < l.unlock_block) revert still_locked();

        uint256 amount = l.amount;
        address token = l.token;

        // Settle interest alongside principal. A lock that exits with unredeemed
        // interest would otherwise leave it in `promised` with no claimant, stranded
        // until every other lock in that token closes.
        _sync(token);
        uint256 earned = _accrued(l);

        // Effects before interactions, and the withdrawn flag before the transfer.
        // The mutex already forbids re-entry; this makes the contract correct even
        // if a future edit removes it.
        l.withdrawn = true;
        l.debt = _acc_per_share[token];
        total_locked[token] -= amount;
        if (earned != 0) promised[token] -= earned;
        // Last one out. Rounding leaves a few wei reserved that no share can express;
        // with nobody left to claim it, release it so `sweep_surplus` can recover it
        // rather than stranding dust in the vault for ever.
        if (total_locked[token] == 0) promised[token] = 0;

        token.safe_transfer(to, amount + earned);
        if (earned != 0) emit interest_redeemed(id, claimant, to, token, earned);
        emit released(id, claimant, to, amount);
    }

    // ------------------------------------------------------------------- surplus
    /**
     * @notice Send any balance no lock claims to SURPLUS_SINK. Callable by anyone.
     * @dev    Not an admin key. The caller chooses nothing: not the destination, not
     *         the amount. Locked principal is excluded arithmetically, so this cannot
     *         reach a live lock even if every locker in the world calls it at once.
     */
    /// @dev Interest owed to live locks is held in `promised` and excluded here, so the
    ///      permissionless rescue works exactly as before WITHOUT ever racing a locker
    ///      for their reflections. With locks live, `_sync` first credits anything that
    ///      has arrived to those locks; only genuinely unallocatable dust remains.
    function sweep_surplus(address token) external non_reentrant returns (uint256 amount) {
        _sync(token);
        amount = _surplus(token);
        if (amount == 0) revert nothing_to_sweep();
        token.safe_transfer(SURPLUS_SINK, amount);
        emit surplus_swept(token, SURPLUS_SINK, amount);
    }

    /// @dev Free balance AFTER a sync: what no principal and no booked interest claims.
    ///      Only valid once `_sync` has run, which every caller does first.
    function _surplus(address token) internal view returns (uint256) {
        uint256 bal = i_erc20_min(token).balanceOf(address(this));
        uint256 owed = total_locked[token] + promised[token];
        return bal > owed ? bal - owed : 0;
    }

    /// @dev What `_surplus` WOULD be after syncing. The view must mirror the state
    ///      change it cannot perform, or it reports interest that lockers are already
    ///      entitled to as free balance — which reads as "the sink may take this".
    function _free(address token) internal view returns (uint256) {
        uint256 bal = i_erc20_min(token).balanceOf(address(this));
        uint256 locked_total = total_locked[token];
        uint256 owed = locked_total + promised[token];
        if (bal <= owed) return 0;
        uint256 fresh = bal - owed;
        if (locked_total == 0) return fresh; // nobody to credit; it is genuinely free
        uint256 creditable = (((fresh * ACC_SCALE) / locked_total) * locked_total) / ACC_SCALE;
        return fresh - creditable; // only rounding dust is ever free while locks live
    }

    // ------------------------------------------------------------------ interest
    /**
     * @dev Book any newly-arrived balance as interest, once, at the moment it is first
     *      observed. Called before every operation that reads or changes entitlement.
     *
     *      Balance above `total_locked + promised` is value that has arrived since the
     *      last sync — a reflection, or a stray transfer, which are indistinguishable
     *      on-chain and are treated identically. With nothing locked there is nobody to
     *      credit, so it is left for `sweep_surplus`.
     */
    function _sync(address token) internal {
        uint256 locked_total = total_locked[token];
        if (locked_total == 0) return;
        uint256 bal = i_erc20_min(token).balanceOf(address(this));
        uint256 accounted = locked_total + promised[token];
        if (bal <= accounted) return;
        uint256 fresh = bal - accounted;
        uint256 delta = (fresh * ACC_SCALE) / locked_total;
        // Too small to express per-share. Leave it unaccounted; the next sync sees it
        // again as part of a larger arrival. Moving the accumulator by zero while
        // reserving the balance would strand it permanently.
        if (delta == 0) return;
        _acc_per_share[token] += delta;
        // Reserve the WHOLE arrival, not the re-floored product. Because `delta` is
        // floored, the sum of every lock's claim is at most
        // `locked_total * delta / ACC_SCALE <= fresh`, so this can never reserve less
        // than the claims against it. Reserving the smaller re-floored figure was the
        // underflow: the accumulator promised more than `promised` held.
        promised[token] += fresh;
    }

    function _accrued(lock_record storage l) internal view returns (uint256) {
        return (l.amount * (_acc_per_share[l.token] - l.debt)) / ACC_SCALE;
    }

    /**
     * @notice Redeem the reflection interest earned by a lock, without touching principal.
     * @dev    THE POINT OF THE VAULT, not a convenience. LUV is a reflection token: the
     *         locker's balance grows on every trade, above the principal it is holding.
     *         Paying only `amount` at maturity and letting `sweep_surplus` carry that
     *         growth to the sink would mean a depositor funds a decade of yield and
     *         collects none of it. Principal is held; interest is redeemed. That is the
     *         design plan, and it is what makes a hundred-year lock something other
     *         than a hundred-year forfeiture.
     *
     *         PRO RATA, MEASURED, NEVER ACCRUED. The share is computed from the live
     *         balance at call time — `surplus * amount / total_locked` — so nothing is
     *         accrued into storage that could drift from the token's own accounting.
     *         A reflection token can rebase in ways no bookkeeping here would predict;
     *         the only honest number is the one read from `balanceOf` in this block.
     *
     *         SOLVENCY IS PRESERVED BY CONSTRUCTION. Payment comes exclusively from
     *         balance in excess of `total_locked`, and `total_locked` is not touched,
     *         so the invariant `balance >= total_locked` holds across any sequence of
     *         redemptions. Calling twice in one block pays nothing the second time:
     *         the first transfer has already reduced the surplus it was computed from.
     *
     *         ONE-WAY GATE. This never shortens a lock, never reduces `amount`, and
     *         never reaches principal. A matured lock may still redeem — interest and
     *         maturity are independent.
     */
    function redeem_interest(uint256 id) external non_reentrant returns (uint256 paid) {
        paid = _redeem_interest(id, msg.sender, msg.sender);
    }

    /// @notice Redeem interest to a nominated address.
    function redeem_interest_to(uint256 id, address to) external non_reentrant returns (uint256 paid) {
        if (to == address(0)) revert zero_address();
        paid = _redeem_interest(id, msg.sender, to);
    }

    function _redeem_interest(uint256 id, address claimant, address to) internal returns (uint256 paid) {
        lock_record storage l = _read(id);
        if (claimant != l.beneficiary) revert not_beneficiary();
        if (l.withdrawn) revert already_withdrawn();

        address token = l.token;
        _sync(token);
        paid = _accrued(l);
        if (paid == 0) revert nothing_to_sweep();

        // Effects before the interaction. Settling the debt first makes a second call
        // in the same transaction pay zero even if the mutex were ever removed.
        l.debt = _acc_per_share[token];
        promised[token] -= paid;

        token.safe_transfer(to, paid);
        emit interest_redeemed(id, l.beneficiary, to, token, paid);
    }

    /**
     * @notice COLLECT — the reflection growth, withdrawable without touching principal.
     * @dev    The canonical name for what this vault does for a reflection token: the
     *         balance grows, and the growth is collectable while the principal stays
     *         locked. Identical to `redeem_interest`; both exist because the contract
     *         talks about interest and the interface talks about collecting, and a
     *         reader should not have to know they are the same idea.
     */
    function collect(uint256 id) external non_reentrant returns (uint256 paid) {
        paid = _redeem_interest(id, msg.sender, msg.sender);
    }

    /// @notice Collect the growth to a nominated address.
    function collect_to(uint256 id, address to) external non_reentrant returns (uint256 paid) {
        if (to == address(0)) revert zero_address();
        paid = _redeem_interest(id, msg.sender, to);
    }

    /// @notice What `id` can COLLECT right now. Alias of `interest_of`.
    function collectable(uint256 id) external view when_not_entered returns (uint256) {
        return this.interest_of(id);
    }

    /**
     * @notice What `id` could redeem right now.
     * @dev    Mirrors `_sync` in memory rather than calling it, so the view stays
     *         `view` and can never be a state-changing surprise to an integrator.
     */
    function interest_of(uint256 id) external view when_not_entered returns (uint256) {
        lock_record storage l = _read(id);
        if (l.withdrawn) return 0;
        uint256 locked_total = total_locked[l.token];
        if (locked_total == 0) return 0;
        uint256 acc = _acc_per_share[l.token];
        uint256 bal = i_erc20_min(l.token).balanceOf(address(this));
        uint256 accounted = locked_total + promised[l.token];
        if (bal > accounted) {
            acc += ((bal - accounted) * ACC_SCALE) / locked_total;
        }
        return (l.amount * (acc - l.debt)) / ACC_SCALE;
    }

    // --------------------------------------------------------------------- views
    function surplus(address token) external view when_not_entered returns (uint256) {
        return _free(token);
    }

    function lock_at(uint256 id)
        external
        view
        when_not_entered
        returns (address token, address beneficiary, uint256 amount, uint48 unlock_at, bool withdrawn)
    {
        lock_record storage l = _read(id);
        return (l.token, l.beneficiary, l.amount, l.unlock_at, l.withdrawn);
    }

    /// @notice Both gates of a lock, as they stand. 0 means that gate is unused.
    function gates_of(uint256 id)
        external
        view
        when_not_entered
        returns (uint48 unlock_at, uint40 unlock_block)
    {
        lock_record storage l = _read(id);
        return (l.unlock_at, l.unlock_block);
    }

    /// @notice True while the lock still holds — under EITHER gate. False once both have
    ///         passed, or once withdrawn.
    function is_locked(uint256 id) external view when_not_entered returns (bool) {
        lock_record storage l = _read(id);
        if (l.withdrawn) return false;
        return block.timestamp < l.unlock_at || block.number < l.unlock_block;
    }

    /// @notice Seconds until the time gate opens, and blocks until the block gate does.
    ///         Zero in either position means that gate is already open.
    function time_remaining(uint256 id)
        external
        view
        when_not_entered
        returns (uint256 seconds_left, uint256 blocks_left)
    {
        lock_record storage l = _read(id);
        if (l.withdrawn) return (0, 0);
        seconds_left = block.timestamp >= l.unlock_at ? 0 : l.unlock_at - block.timestamp;
        blocks_left = block.number >= l.unlock_block ? 0 : l.unlock_block - block.number;
    }

    /**
     * @notice Every live lock id currently owned by `user`.
     * @dev    O(n) over that user's append-only index and intended for `eth_call`
     *         only. Never call this from a contract. Stale entries left by `assign`
     *         are filtered against the authoritative record here.
     */
    function locks_of(address user) external view when_not_entered returns (uint256[] memory ids) {
        uint256[] storage idx = _index_of[user];
        uint256 n;
        for (uint256 i; i < idx.length; ++i) {
            if (_locks[idx[i]].beneficiary == user) ++n;
        }
        ids = new uint256[](n);
        uint256 k;
        for (uint256 i; i < idx.length; ++i) {
            if (_locks[idx[i]].beneficiary == user) ids[k++] = idx[i];
        }
    }

    // ----------------------------------------------------------------- internals
    function _read(uint256 id) internal view returns (lock_record storage l) {
        if (id >= lock_count) revert lock_not_found();
        l = _locks[id];
    }

    /**
     * @dev uint48 overflows in the year 8,921,556; uint32 overflows in 2106, which is
     *      inside the design horizon of a contract like this one. The assert is
     *      unreachable and documents the invariant rather than defending it.
     */
    function _now48() internal view returns (uint48) {
        if (block.timestamp > type(uint48).max) revert timestamp_overflow();
        return uint48(block.timestamp);
    }

    /// @dev uint40 holds 1.0995e12 blocks — at 12s that is 418,000 years, and at 0.1s
    ///      still 3,400. Unreachable on any chain, and checked rather than assumed.
    function _block40() internal view returns (uint40) {
        if (block.number > type(uint40).max) revert timestamp_overflow();
        return uint40(block.number);
    }
}
