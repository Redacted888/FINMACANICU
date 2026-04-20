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
