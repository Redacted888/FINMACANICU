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
