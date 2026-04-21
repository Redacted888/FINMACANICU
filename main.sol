// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/*
    FINMACANICU — Terminal-grade bookmaking + risk ledger

    A compact on-chain "finance desk" for quotes, matched bets, and settlement.
    It aims for boring-mainnet behavior: pull-based payouts, explicit roles,
    and a clearly auditable risk envelope with circuit breakers.
*/

/// @dev Minimal interface for ERC20 transfers (optional collateral tokens).
interface IERC20Like {
    function totalSupply() external view returns (uint256);
    function balanceOf(address who) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @dev A small, explicit safe-transfer wrapper supporting non-standard tokens.
library SafeToken {
    error SafeTokenCallFailed();
    error SafeTokenBadReturn();

    function _call(address token, bytes memory data) private returns (bytes memory ret) {
        (bool ok, bytes memory r) = token.call(data);
        if (!ok) revert SafeTokenCallFailed();
        return r;
    }

    function safeTransfer(address token, address to, uint256 amount) internal {
        bytes memory ret = _call(token, abi.encodeWithSelector(IERC20Like.transfer.selector, to, amount));
        if (ret.length != 0 && (ret.length != 32 || abi.decode(ret, (bool)) != true)) revert SafeTokenBadReturn();
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        bytes memory ret = _call(token, abi.encodeWithSelector(IERC20Like.transferFrom.selector, from, to, amount));
        if (ret.length != 0 && (ret.length != 32 || abi.decode(ret, (bool)) != true)) revert SafeTokenBadReturn();
    }
}

library FMTypes {
    enum Side {
        Back,
        Lay
    }

    enum MarketStatus {
        None,
        Open,
        Halted,
        Settled,
        Voided
    }

    struct MarketConfig {
        uint32 closeTime;
        uint32 settleDeadline;
        uint16 feeBps;
        uint16 makerRebateBps;
        uint16 maxOrdersPerUser;
        uint8 outcomes;
        bool allowUnmatched;
        uint64 minStake;
        uint64 maxStake;
    }

    struct RiskCaps {
        uint64 maxMarketNotional;
        uint64 maxUserNotional;
        uint32 maxExposureWindow;
        uint16 maxFeeBps;
        uint16 maxRebateBps;
    }

    struct Quote {
        uint64 priceE4;
        uint64 size;
        uint32 expiry;
        uint8 outcome;
        Side side;
        address maker;
        bytes32 quoteId;
    }

    struct MatchedBet {
        uint64 priceE4;
        uint64 stake;
        uint8 outcome;
        Side takerSide;
        address maker;
        address taker;
        bytes32 matchId;
    }

    struct BalanceSlot {
        uint128 available;
        uint128 locked;
    }

    struct ExposureSlot {
        uint128 notional;
        uint64 lastTouch;
        uint64 reserved;
    }
}

library FMFixed {
    error FMFixedOverflow();
    error FMFixedDivZero();

    function mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        if (d == 0) revert FMFixedDivZero();
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) return prod0 / d;
            if (d <= prod1) revert FMFixedOverflow();
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, d)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = d & (~d + 1);
            assembly {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inv = (3 * d) ^ 2;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            return prod0 * inv;
        }
    }

    function fee(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps) / 10_000;
    }

    function clampU64(uint256 x) internal pure returns (uint64) {
        if (x > type(uint64).max) revert FMFixedOverflow();
        return uint64(x);
    }
}

abstract contract ReentrancyShield {
    error Reentrancy();
    uint256 private _lock;

    modifier nonReentrant() {
        if (_lock != 0) revert Reentrancy();
        _lock = 1;
        _;
        _lock = 0;
    }
}

abstract contract OwnableSteps {
    error NotOwner();
    error NotPendingOwner();
    event OwnershipTransferInitiated(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    address public owner;
    address public pendingOwner;

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address next) external onlyOwner {
        pendingOwner = next;
        emit OwnershipTransferInitiated(owner, next);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address prev = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(prev, owner);
    }
}

abstract contract PausableSwitch is OwnableSteps {
    error Paused();
    error NotPaused();
    event PausedState(bool paused);

    bool public paused;

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier whenPaused() {
        if (!paused) revert NotPaused();
        _;
    }

    function pause() external onlyOwner whenNotPaused {
        paused = true;
        emit PausedState(true);
    }

    function unpause() external onlyOwner whenPaused {
        paused = false;
        emit PausedState(false);
    }
}

contract FinMacanicu is PausableSwitch, ReentrancyShield {
    using SafeToken for address;

    // ---------------------------
    // Unique identifiers (bytes32)
    // ---------------------------
    bytes32 public constant FMK_DOMAIN = keccak256("FinMacanicu.FMK_DOMAIN.v7.terminal");
    bytes32 public constant FMK_LEDGER = keccak256("FinMacanicu.FMK_LEDGER.alpha.signedRisk");
    bytes32 public constant FMK_RISK_SALT = 0x512904022709deb9416b91058e12efd1377158b5fe4f4a055b9eca0749836d43;
    bytes32 public constant FMK_ROUTE_SEED = 0x2367999dc78be26e203ffe884f9feaaf9924b6af4e8319c9dce2c2b03ef7db29;
    bytes32 public constant FMK_ORDER_SEED = 0x56624119aced4476100abc669d8547080eb55bbbfd59459ae405b6a628f852a6;
    bytes32 public constant FMK_MATCH_SEED = 0xd2a28a68968de1a454bd8486974cb40e3c78bd27340fc6221143c928bf475e8e;
    bytes32 public constant FMK_AUDIT_TAG = 0x0305c8f3e20a7bd7f2399ed3e8cdb417c235f30f43e02a297a15cbfe566af1e1;
    bytes32 public constant FMK_ENGINE_TAG = 0x0485644730f1b925edb24ef9b2bff11fa895fc7cf8b837e4fff32c840c3c392b;

    // ---------------------------
    // Roles (simple mapping)
    // ---------------------------
    bytes32 public constant ROLE_RISK = keccak256("FinMacanicu.ROLE_RISK");
    bytes32 public constant ROLE_ORACLE = keccak256("FinMacanicu.ROLE_ORACLE");
    bytes32 public constant ROLE_BOOK = keccak256("FinMacanicu.ROLE_BOOK");
    bytes32 public constant ROLE_TREASURY = keccak256("FinMacanicu.ROLE_TREASURY");
    bytes32 public constant ROLE_GUARDIAN = keccak256("FinMacanicu.ROLE_GUARDIAN");

    mapping(bytes32 role => address who) public roleHolder;

    // ---------------------------
    // Unique default addresses (checksummed)
    // ---------------------------
    address public treasurySink;
    address public oracleSink;
    address public riskSink;
    address public guardianSink;
    address public bookSink;

    // ---------------------------
    // Collateral
    // ---------------------------
    address public immutable collateralToken; // address(0) => native
    uint8 public immutable collateralDecimals;

    // ---------------------------
    // Risk envelope
    // ---------------------------
    FMTypes.RiskCaps public caps;
    uint64 public globalOpenNotional;

    // ---------------------------
    // Accounting
    // ---------------------------
    mapping(address user => FMTypes.BalanceSlot) internal _bal;
    mapping(uint64 marketId => uint64 openNotional) public marketOpenNotional;
    mapping(address user => FMTypes.ExposureSlot) public userExposure;

    // ---------------------------
    // Markets and orders
    // ---------------------------
    uint64 public marketCount;
    mapping(uint64 marketId => FMTypes.MarketConfig) public marketConfig;
    mapping(uint64 marketId => FMTypes.MarketStatus) public marketStatus;
    mapping(uint64 marketId => uint8 settledOutcome) public marketResult;

    mapping(uint64 marketId => bytes32) public marketKey;
    mapping(uint64 marketId => string) internal _marketLabel;

    struct QuoteState {
        address maker;
        uint64 priceE4;
        uint64 remaining;
        uint32 expiry;
        uint8 outcome;
        FMTypes.Side side;
        bool cancelled;
    }

    mapping(bytes32 quoteId => QuoteState) public quotes;
    mapping(uint64 marketId => bytes32[]) internal _marketQuoteIds;
    mapping(address user => uint16) public openOrderCount;

    struct MatchState {
        address maker;
        address taker;
        uint64 priceE4;
        uint64 stake;
        uint8 outcome;
        FMTypes.Side takerSide;
        bool claimedMaker;
        bool claimedTaker;
    }

    mapping(bytes32 matchId => MatchState) public matches;
    mapping(uint64 marketId => bytes32[]) internal _marketMatchIds;

    // ---------------------------
    // Withdrawal escrow (pull)
    // ---------------------------
    mapping(address user => uint128) public pendingPayout;

    // ---------------------------
    // Safety / sequencing
    // ---------------------------
    uint64 public quoteNonce;
    uint64 public matchNonce;
    uint64 public marketNonce;

    // ---------------------------
    // Events (varied, unique)
    // ---------------------------
    event DeskRoleSet(bytes32 indexed role, address indexed previous, address indexed next);
    event DeskSinksRotated(address treasury, address oracle, address risk, address guardian, address book);
    event CollateralDeposited(address indexed user, address indexed asset, uint256 amount, uint256 newAvail);
    event CollateralWithdrawQueued(address indexed user, uint256 amount, uint256 newPending);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event MarketListed(uint64 indexed marketId, bytes32 indexed key, uint32 closeTime, uint8 outcomes, string label);
    event MarketHalt(uint64 indexed marketId, address indexed by, uint8 reasonCode);
    event MarketResume(uint64 indexed marketId, address indexed by);
    event MarketSettled(uint64 indexed marketId, uint8 outcome, address indexed oracle);
    event MarketVoided(uint64 indexed marketId, uint8 reason, address indexed by);
    event QuotePosted(uint64 indexed marketId, bytes32 indexed quoteId, address indexed maker, uint8 outcome, uint64 priceE4, uint64 size, uint32 expiry, FMTypes.Side side);
    event QuoteReduced(bytes32 indexed quoteId, uint64 newRemaining, uint8 flags);
    event QuoteCancelled(bytes32 indexed quoteId, address indexed by);
    event BetMatched(uint64 indexed marketId, bytes32 indexed matchId, address indexed maker, address indexed taker, uint8 outcome, uint64 priceE4, uint64 stake, FMTypes.Side takerSide);
    event BetClaimed(uint64 indexed marketId, bytes32 indexed matchId, address indexed claimant, uint256 netPaid, uint256 feePaid);
    event CapsUpdated(FMTypes.RiskCaps caps);
    event FeeScheduleUpdated(uint64 indexed marketId, uint16 feeBps, uint16 makerRebateBps);
    event ExposureTouched(address indexed user, uint128 notional, uint64 ts);

    // ---------------------------
    // Errors (varied, unique)
    // ---------------------------
    error FMK_BadRole();
    error FMK_NotRole(bytes32 role);
    error FMK_BadAmount();
    error FMK_BadPrice();
    error FMK_BadOutcome();
    error FMK_BadMarket();
    error FMK_MarketClosed();
    error FMK_MarketNotOpen();
    error FMK_MarketNotSettled();
    error FMK_AlreadyFinal();
    error FMK_Expired();
    error FMK_TooManyOrders();
    error FMK_NoLiquidity();
    error FMK_RiskLimit();
    error FMK_Insufficient();
    error FMK_TransferFailed();
    error FMK_NativeValueMismatch();
    error FMK_BadConfig();
    error FMK_Claimed();
    error FMK_NotParticipant();

    // ---------------------------
    // Constructor
    // ---------------------------
    constructor(address collateral_) {
        collateralToken = collateral_;
        if (collateral_ == address(0)) {
            collateralDecimals = 18;
        } else {
            uint8 dec = IERC20Like(collateral_).decimals();
            collateralDecimals = dec;
        }

        // Populate sinks with checksummed, mixed-case addresses (can be rotated by owner later).
        treasurySink = 0x53Fb09Cb3b3806B272d5A0122673E4c8474a5295;
        oracleSink = 0xE93f2C5E704EAB89394Ff3b7D095797058E039e8;
        riskSink = 0xd79ef7974033b8085c282c8B7FaB3DA3242B3a0f;
        guardianSink = 0x8043d49d7c4d0038C7088D598900A39c6c1Db9a1;
        bookSink = 0xA377e85e7f7C5d3fC15b688632E0f06140Aa8DE3;

        roleHolder[ROLE_TREASURY] = treasurySink;
        roleHolder[ROLE_ORACLE] = oracleSink;
        roleHolder[ROLE_RISK] = riskSink;
        roleHolder[ROLE_GUARDIAN] = guardianSink;
        roleHolder[ROLE_BOOK] = bookSink;

        emit DeskSinksRotated(treasurySink, oracleSink, riskSink, guardianSink, bookSink);
        emit DeskRoleSet(ROLE_TREASURY, address(0), treasurySink);
        emit DeskRoleSet(ROLE_ORACLE, address(0), oracleSink);
        emit DeskRoleSet(ROLE_RISK, address(0), riskSink);
        emit DeskRoleSet(ROLE_GUARDIAN, address(0), guardianSink);
        emit DeskRoleSet(ROLE_BOOK, address(0), bookSink);

        caps = FMTypes.RiskCaps({
            maxMarketNotional: 9_100_000,
            maxUserNotional: 210_000,
            maxExposureWindow: 97_000,
            maxFeeBps: 420,
            maxRebateBps: 175
        });
        emit CapsUpdated(caps);
    }

    // ---------------------------
    // Role admin functions
    // ---------------------------
    function setRole(bytes32 role, address who) external onlyOwner {
        if (
            role != ROLE_RISK && role != ROLE_ORACLE && role != ROLE_BOOK && role != ROLE_TREASURY && role != ROLE_GUARDIAN
        ) revert FMK_BadRole();
        address prev = roleHolder[role];
        roleHolder[role] = who;
        emit DeskRoleSet(role, prev, who);
    }

    function rotateSinks(address treasury, address oracle, address risk, address guardian, address book) external onlyOwner {
        treasurySink = treasury;
        oracleSink = oracle;
        riskSink = risk;
        guardianSink = guardian;
        bookSink = book;

        roleHolder[ROLE_TREASURY] = treasury;
        roleHolder[ROLE_ORACLE] = oracle;
        roleHolder[ROLE_RISK] = risk;
        roleHolder[ROLE_GUARDIAN] = guardian;
        roleHolder[ROLE_BOOK] = book;

        emit DeskSinksRotated(treasury, oracle, risk, guardian, book);
    }

    modifier onlyRole(bytes32 role) {
        if (msg.sender != roleHolder[role] && msg.sender != owner) revert FMK_NotRole(role);
        _;
    }

    // ---------------------------
    // Caps management
    // ---------------------------
    function setCaps(FMTypes.RiskCaps calldata next) external onlyRole(ROLE_RISK) {
        if (next.maxFeeBps > 10_000 || next.maxRebateBps > 10_000) revert FMK_BadConfig();
        if (next.maxRebateBps > next.maxFeeBps) revert FMK_BadConfig();
        if (next.maxMarketNotional == 0 || next.maxUserNotional == 0) revert FMK_BadConfig();
        caps = next;
        emit CapsUpdated(next);
    }

    // ---------------------------
    // Market management
    // ---------------------------
    function marketLabel(uint64 marketId) external view returns (string memory) {
        return _marketLabel[marketId];
    }

    function listMarket(bytes32 key, FMTypes.MarketConfig calldata cfg, string calldata label)
        external
        onlyRole(ROLE_BOOK)
        whenNotPaused
        returns (uint64 marketId)
    {
        if (cfg.outcomes < 2 || cfg.outcomes > 8) revert FMK_BadConfig();
        if (cfg.closeTime <= block.timestamp) revert FMK_BadConfig();
        if (cfg.settleDeadline <= cfg.closeTime) revert FMK_BadConfig();
        if (cfg.feeBps > caps.maxFeeBps) revert FMK_BadConfig();
        if (cfg.makerRebateBps > caps.maxRebateBps) revert FMK_BadConfig();
        if (cfg.makerRebateBps > cfg.feeBps) revert FMK_BadConfig();
        if (cfg.maxStake < cfg.minStake || cfg.minStake == 0) revert FMK_BadConfig();
        if (marketStatus[++marketCount] != FMTypes.MarketStatus.None) revert FMK_BadMarket();

        marketId = marketCount;
        marketKey[marketId] = key;
        _marketLabel[marketId] = label;
        marketConfig[marketId] = cfg;
        marketStatus[marketId] = FMTypes.MarketStatus.Open;
        marketNonce++;
        emit MarketListed(marketId, key, cfg.closeTime, cfg.outcomes, label);
    }

    function haltMarket(uint64 marketId, uint8 reason) external onlyRole(ROLE_GUARDIAN) {
        FMTypes.MarketStatus st = marketStatus[marketId];
        if (st != FMTypes.MarketStatus.Open) revert FMK_MarketNotOpen();
        marketStatus[marketId] = FMTypes.MarketStatus.Halted;
        emit MarketHalt(marketId, msg.sender, reason);
    }

    function resumeMarket(uint64 marketId) external onlyRole(ROLE_GUARDIAN) {
        FMTypes.MarketStatus st = marketStatus[marketId];
        if (st != FMTypes.MarketStatus.Halted) revert FMK_MarketNotOpen();
        marketStatus[marketId] = FMTypes.MarketStatus.Open;
        emit MarketResume(marketId, msg.sender);
    }

    function voidMarket(uint64 marketId, uint8 reason) external onlyRole(ROLE_GUARDIAN) {
        FMTypes.MarketStatus st = marketStatus[marketId];
        if (st == FMTypes.MarketStatus.Settled || st == FMTypes.MarketStatus.Voided) revert FMK_AlreadyFinal();
        marketStatus[marketId] = FMTypes.MarketStatus.Voided;
        marketResult[marketId] = 0;
        emit MarketVoided(marketId, reason, msg.sender);
    }

    function setFeeSchedule(uint64 marketId, uint16 feeBps, uint16 makerRebateBps) external onlyRole(ROLE_RISK) {
        if (feeBps > caps.maxFeeBps) revert FMK_BadConfig();
        if (makerRebateBps > caps.maxRebateBps) revert FMK_BadConfig();
        if (makerRebateBps > feeBps) revert FMK_BadConfig();
        FMTypes.MarketConfig storage cfg = marketConfig[marketId];
        if (marketStatus[marketId] == FMTypes.MarketStatus.None) revert FMK_BadMarket();
        cfg.feeBps = feeBps;
        cfg.makerRebateBps = makerRebateBps;
        emit FeeScheduleUpdated(marketId, feeBps, makerRebateBps);
    }

    // ---------------------------
    // Deposits / withdrawals
    // ---------------------------
    receive() external payable {
        if (collateralToken != address(0)) revert FMK_TransferFailed();
        _depositNative(msg.sender, msg.value);
    }

    function deposit(uint256 amount) external payable whenNotPaused nonReentrant {
        if (collateralToken == address(0)) {
            if (msg.value != amount) revert FMK_NativeValueMismatch();
            _depositNative(msg.sender, amount);
        } else {
            if (msg.value != 0) revert FMK_NativeValueMismatch();
            if (amount == 0) revert FMK_BadAmount();
            collateralToken.safeTransferFrom(msg.sender, address(this), amount);
            _bal[msg.sender].available += uint128(amount);
            emit CollateralDeposited(msg.sender, collateralToken, amount, _bal[msg.sender].available);
        }
    }

    function _depositNative(address user, uint256 amount) internal {
        if (amount == 0) revert FMK_BadAmount();
        _bal[user].available += uint128(amount);
        emit CollateralDeposited(user, address(0), amount, _bal[user].available);
    }

    function balanceOf(address user) external view returns (uint256 available, uint256 locked) {
        FMTypes.BalanceSlot memory b = _bal[user];
        return (b.available, b.locked);
    }

    function queueWithdraw(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert FMK_BadAmount();
        FMTypes.BalanceSlot storage b = _bal[msg.sender];
        if (b.available < amount) revert FMK_Insufficient();
        b.available -= uint128(amount);
        pendingPayout[msg.sender] += uint128(amount);
        emit CollateralWithdrawQueued(msg.sender, amount, pendingPayout[msg.sender]);
    }

    function withdraw() external nonReentrant {
        uint128 amt = pendingPayout[msg.sender];
        if (amt == 0) revert FMK_BadAmount();
        pendingPayout[msg.sender] = 0;
        _payout(msg.sender, amt);
        emit CollateralWithdrawn(msg.sender, amt);
    }

    function _payout(address to, uint256 amount) internal {
        if (collateralToken == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert FMK_TransferFailed();
        } else {
            collateralToken.safeTransfer(to, amount);
        }
    }

    // ---------------------------
    // Quote engine
    // ---------------------------
    function postQuote(
        uint64 marketId,
        uint8 outcome,
        FMTypes.Side side,
        uint64 priceE4,
        uint64 size,
        uint32 expiry
    ) external whenNotPaused nonReentrant returns (bytes32 quoteId) {
        FMTypes.MarketConfig memory cfg = marketConfig[marketId];
        if (marketStatus[marketId] != FMTypes.MarketStatus.Open) revert FMK_MarketNotOpen();
        if (block.timestamp >= cfg.closeTime) revert FMK_MarketClosed();
        if (outcome == 0 || outcome > cfg.outcomes) revert FMK_BadOutcome();
        if (priceE4 < 1_000 || priceE4 > 99_900) revert FMK_BadPrice(); // 0.1000..9.9900 (terminal-ish odds scale)
        if (size < cfg.minStake || size > cfg.maxStake) revert FMK_BadAmount();
        if (expiry <= block.timestamp) revert FMK_Expired();
        if (openOrderCount[msg.sender] >= cfg.maxOrdersPerUser) revert FMK_TooManyOrders();

        _touchExposure(msg.sender);
        uint256 lockReq = _lockFor(side, priceE4, size);
        _lockFunds(msg.sender, lockReq);

        quoteNonce++;
        quoteId = keccak256(abi.encodePacked(FMK_ORDER_SEED, block.chainid, address(this), msg.sender, marketId, quoteNonce, outcome, side, priceE4, size, expiry));
        QuoteState storage qs = quotes[quoteId];
        if (qs.maker != address(0)) revert FMK_BadMarket();

        qs.maker = msg.sender;
        qs.priceE4 = priceE4;
        qs.remaining = size;
        qs.expiry = expiry;
        qs.outcome = outcome;
        qs.side = side;
        qs.cancelled = false;

        _marketQuoteIds[marketId].push(quoteId);
        openOrderCount[msg.sender] += 1;
        emit QuotePosted(marketId, quoteId, msg.sender, outcome, priceE4, size, expiry, side);
    }

    function reduceQuote(bytes32 quoteId, uint64 newRemaining, uint8 flags) external nonReentrant {
        QuoteState storage qs = quotes[quoteId];
        if (qs.maker == address(0)) revert FMK_BadMarket();
        if (qs.maker != msg.sender && msg.sender != owner) revert FMK_NotParticipant();
        if (qs.cancelled) revert FMK_AlreadyFinal();
        if (newRemaining > qs.remaining) revert FMK_BadAmount();

        uint64 oldRemaining = qs.remaining;
        qs.remaining = newRemaining;
        if (oldRemaining > newRemaining) {
            uint256 unlock = _lockFor(qs.side, qs.priceE4, oldRemaining - newRemaining);
            _unlockFunds(qs.maker, unlock);
        }
        emit QuoteReduced(quoteId, newRemaining, flags);
    }

    function cancelQuote(bytes32 quoteId) external nonReentrant {
        QuoteState storage qs = quotes[quoteId];
        if (qs.maker == address(0)) revert FMK_BadMarket();
        if (qs.maker != msg.sender && msg.sender != owner && msg.sender != roleHolder[ROLE_GUARDIAN]) revert FMK_NotParticipant();
        if (qs.cancelled) revert FMK_AlreadyFinal();

        qs.cancelled = true;
        if (qs.remaining != 0) {
            uint256 unlock = _lockFor(qs.side, qs.priceE4, qs.remaining);
            _unlockFunds(qs.maker, unlock);
        }
        qs.remaining = 0;
        openOrderCount[qs.maker] = openOrderCount[qs.maker] == 0 ? 0 : (openOrderCount[qs.maker] - 1);
        emit QuoteCancelled(quoteId, msg.sender);
    }

    function getMarketQuotes(uint64 marketId) external view returns (bytes32[] memory) {
        return _marketQuoteIds[marketId];
    }

    // ---------------------------
    // Matching engine
    // ---------------------------
    function takeQuote(uint64 marketId, bytes32 quoteId, uint64 stake) external whenNotPaused nonReentrant returns (bytes32 matchId) {
        FMTypes.MarketConfig memory cfg = marketConfig[marketId];
        if (marketStatus[marketId] != FMTypes.MarketStatus.Open) revert FMK_MarketNotOpen();
        if (block.timestamp >= cfg.closeTime) revert FMK_MarketClosed();
        if (stake < cfg.minStake || stake > cfg.maxStake) revert FMK_BadAmount();

        QuoteState storage qs = quotes[quoteId];
        if (qs.maker == address(0)) revert FMK_BadMarket();
        if (qs.cancelled) revert FMK_AlreadyFinal();
        if (qs.remaining == 0) revert FMK_NoLiquidity();
        if (qs.expiry <= block.timestamp) revert FMK_Expired();
        if (stake > qs.remaining) stake = qs.remaining;
        if (qs.maker == msg.sender) revert FMK_NotParticipant();
        if (qs.outcome == 0 || qs.outcome > cfg.outcomes) revert FMK_BadOutcome();

        _touchExposure(msg.sender);
        uint256 takerLock = _lockFor(_invertSide(qs.side), qs.priceE4, stake);
        _lockFunds(msg.sender, takerLock);

        // Decrement maker quote and release excess maker lock delta is handled by reduceQuote-style logic here.
        qs.remaining -= stake;
        if (qs.remaining == 0) {
            openOrderCount[qs.maker] = openOrderCount[qs.maker] == 0 ? 0 : (openOrderCount[qs.maker] - 1);
        }

        matchNonce++;
        matchId = keccak256(abi.encodePacked(FMK_MATCH_SEED, block.chainid, address(this), marketId, matchNonce, quoteId, qs.maker, msg.sender, qs.outcome, qs.side, qs.priceE4, stake));
        MatchState storage ms = matches[matchId];
        if (ms.maker != address(0)) revert FMK_BadMarket();

        ms.maker = qs.maker;
        ms.taker = msg.sender;
        ms.priceE4 = qs.priceE4;
        ms.stake = stake;
        ms.outcome = qs.outcome;
        ms.takerSide = _invertSide(qs.side);
        ms.claimedMaker = false;
        ms.claimedTaker = false;

        _marketMatchIds[marketId].push(matchId);
        _bookNotional(marketId, qs.maker, msg.sender, qs.priceE4, stake);
