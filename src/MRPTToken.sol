// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.19;

import { IMRPTToken } from "./interfaces/IMRPTToken.sol";
import { IReceiveTransferCallback } from "./interfaces/IReceiveTransferCallback.sol";

import { AddressTypeCast } from "./libraries/AddressTypeCast.sol";
import { Message } from "./libraries/Message.sol";
import { Ownable } from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { ERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { VestingWallet } from "lib/openzeppelin-contracts/contracts/finance/VestingWallet.sol";
import { ExcessivelySafeCall } from "./libraries/ExcessivelySafeCall.sol";

import { LayerZeroAdapter } from "./adapters/LayerZeroAdapter.sol";
import { WormholeAdapter } from "./adapters/WormholeAdapter.sol";

contract MRPTToken is IMRPTToken, Ownable, ERC20, WormholeAdapter, LayerZeroAdapter {
    using Message for bytes;
    using AddressTypeCast for bytes32;
    using AddressTypeCast for address;
    using ExcessivelySafeCall for address;

    uint256 constant DEFAULT_GAS_LIMIT = 500_000;
    uint256 public constant MAX_SUPPLY = 900e24;

    uint64 public constant ECOSYSTEM_VESTING_DURATION = 20 * 30 days;
    uint64 public constant ECOSYSTEM_VESTING_DELAY = 9 * 30 days;
    uint64 public constant ECOSYSTEM_PERCENT = 2000;

    uint64 public constant MARTKETING_VESTING_DURATION = 20 * 30 days;
    uint64 public constant MARKETING_VESTING_DELAY = 5 * 30 days;
    uint64 public constant MARKETING_PERCENT = 1800;

    uint64 public constant STAKING_VESTING_DURATION = 60 * 30 days;
    uint64 public constant STAKING_VESTING_DELAY = 0;
    uint64 public constant STAKING_PERCENT = 2100;

    uint64 public constant TEAM_VESTING_DURATION = 20 * 30 days;
    uint64 public constant TEAM_VESTING_DELAY = 12 * 30 days;
    uint64 public constant TEAM_PERCENT = 1000;

    uint64 public constant ADVISOR_VESTING_DURATION = 20 * 30 days;
    uint64 public constant ADVISOR_VESTING_DELAY = 10 * 30 days;
    uint64 public constant ADVISOR_PERCENT = 500;

    address public FEE_RECEIVER;
    uint256 public TRANSFER_FEE;
    // uint256 public mintable;

    event VestingStarted(address beneficiaryAddress, address vestingWallet);

    constructor(
        uint64 startVestingTimestamp,
        address ecoSystem,
        address marketing,
        address stakingRewards,
        address team,
        address advisors
    )
        Ownable()
        ERC20("Marpto", "MRPT")
    {
        // mintable = MAX_SUPPLY;

        // Ecosystem - 20% 9 months cliff and 5% monthly for 20 months
        _startVesting(
            ecoSystem, startVestingTimestamp, ECOSYSTEM_VESTING_DELAY, ECOSYSTEM_VESTING_DURATION, ECOSYSTEM_PERCENT
        );

        // Marketing - 18% 5 months cliff and 5% monthly for 20 months
        _startVesting(
            marketing, startVestingTimestamp, MARKETING_VESTING_DELAY, MARTKETING_VESTING_DURATION, MARKETING_PERCENT
        );

        // Staking Rewards - 21% Linear vesting for 60 Months
        _startVesting(
            stakingRewards, startVestingTimestamp, STAKING_VESTING_DELAY, STAKING_VESTING_DURATION, STAKING_PERCENT
        );

        // Team - 10% 12 months Cliff 5% monthly for 20 Months
        _startVesting(team, startVestingTimestamp, TEAM_VESTING_DELAY, TEAM_VESTING_DURATION, TEAM_PERCENT);

        // Advisors - 5% 10 Months cliff and 5% monthly for 20 months
        _startVesting(advisors, startVestingTimestamp, ADVISOR_VESTING_DELAY, ADVISOR_VESTING_DURATION, ADVISOR_PERCENT);
    }

    function _startVesting(
        address beneficiaryAddress,
        uint64 startVestingTimestamp,
        uint64 cliffSeconds,
        uint64 durationSeconds,
        uint64 proportion
    )
        internal
    {
        address vestingWallet =
            address(new VestingWallet(beneficiaryAddress, startVestingTimestamp + cliffSeconds, durationSeconds));
        uint256 amount = MAX_SUPPLY * proportion / 10_000;
        // mintable -= amount;
        _mint(vestingWallet, amount);
        emit VestingStarted(beneficiaryAddress, vestingWallet);
    }

    // function mint(address account, uint256 amount) external onlyOwner {
    //     mintable -= amount;
    //     _mint(account, amount);
    // }

    function setFeeOption(address feeReceiver, uint256 amount) external onlyOwner {
        FEE_RECEIVER = feeReceiver;
        TRANSFER_FEE = amount;
    }

    /// @inheritdoc IMRPTToken
    function transferFrom(
        uint16 dstChainId,
        address from,
        bytes32 to,
        uint256 value,
        AdapterCallParams calldata params
    )
        external
        payable
        override
    {
        // Get fee before transfer
        uint256 feeAmount = value * TRANSFER_FEE / 1000;
        super.transferFrom(_msgSender(), FEE_RECEIVER, feeAmount);

        _remoteTransfer(dstChainId, from, to, value - feeAmount, params);
    }

    /// @inheritdoc IMRPTToken
    function transferFromWithCallback(
        uint16 dstChainId,
        address from,
        bytes32 to,
        uint256 value,
        uint64 gasForCallback,
        bytes calldata payload,
        AdapterCallParams calldata params
    )
        external
        payable
        override
    {
        // Get fee before transfer
        uint256 feeAmount = value * TRANSFER_FEE / 1000;
        super.transferFrom(_msgSender(), FEE_RECEIVER, feeAmount);

        _remoteTransferWithCallback(dstChainId, from, to, value, gasForCallback, payload, params);
    }

    /// @inheritdoc IMRPTToken
    function circulatingSupply() external view override returns (uint256) {
        return totalSupply();
    }

    function _normalizeAmount(uint256 _amount) internal view returns (uint64) {
        uint8 _decimals = decimals();

        if (_decimals > 8) {
            _amount /= 10 ** (_decimals - 8);
        }

        return uint64(_amount);
    }

    function _deNormalizeAmount(uint64 _amount) internal view returns (uint256 amount) {
        amount = uint256(_amount);
        uint8 _decimals = decimals();

        if (_decimals > 8) {
            amount *= 10 ** (_decimals - 8);
        }

        return amount;
    }

    function _transferFrom(address _from, address _to, uint256 _amount) internal {
        address spender = _msgSender();

        if (_from != address(this) && _from != spender) {
            _spendAllowance(_from, spender, _amount);
        }

        _transfer(_from, _to, _amount);
    }

    function tryCallback(
        uint16 srcChainId,
        bytes calldata srcAddress,
        uint64,
        /**
         * nonce
         */
        bytes32 from,
        address to,
        uint256 amount,
        uint256 gasForCall,
        bytes calldata payload
    )
        public
    {
        if (_msgSender() != address(this)) revert NotOminiFungible();

        _transferFrom(address(this), to, amount);
        emit RemoteTransferReceived(srcChainId, to, amount);

        IReceiveTransferCallback(to).onReceiveTransfer{ gas: gasForCall }(srcChainId, srcAddress, from, amount, payload);
    }

    function _remoteTransfer(
        uint16 dstChainId,
        address from,
        bytes32 to,
        uint256 value,
        AdapterCallParams memory params
    )
        internal
    {
        uint64 normalizedAmount = _normalizeAmount(value);
        bytes memory payload = Message.encodeTransfer(to, normalizedAmount);

        address spender = _msgSender();
        Message.Channel channel = Message.Channel(params.adapter);

        if (from != spender) _spendAllowance(from, spender, value);

        _burn(from, value);

        if (channel == Message.Channel.LAYERZERO) {
            bytes memory remoteRouter = lzState.routers[dstChainId];
            bytes memory adapterParams = _lzAdapterParam(DEFAULT_GAS_LIMIT);
            //TODO: ensure remoteRouter is valid
            _lzSend(dstChainId, remoteRouter, payload, params.refundAddress, address(0), adapterParams, msg.value);
        } else if (channel == Message.Channel.WORMHOLE) {
            address remoteRouter = AddressTypeCast.bytes32ToAddress(wormholeState.routers[dstChainId]);
            _whSend(dstChainId, remoteRouter, _msgSender(), DEFAULT_GAS_LIMIT, 0, payload);
        } else {
            revert UnsupportedAction();
        }

        emit RemoteTransfer(dstChainId, to, from, value);
    }

    function _remoteTransferWithCallback(
        uint16 dstChainId,
        address from,
        bytes32 to,
        uint256 value,
        uint64 gasForCallback,
        bytes calldata payload,
        AdapterCallParams calldata params
    )
        internal
    {
        uint64 normalizedAmount = _normalizeAmount(value);
        bytes memory _payload =
            Message.encodeTransferWithCallback(from.addressToBytes32(), to, normalizedAmount, gasForCallback, payload);

        address spender = _msgSender();
        Message.Channel channel = Message.Channel(params.adapter);

        if (from != spender) _spendAllowance(from, spender, value);

        _burn(from, value);

        if (channel == Message.Channel.LAYERZERO) {
            bytes memory remoteRouter = lzState.routers[dstChainId];
            bytes memory adapterParams =
                _lzAdapterParam(DEFAULT_GAS_LIMIT, AddressTypeCast.bytes32ToAddress(to), gasForCallback);
            /// TODO: ensure valid remoteRouter
            _lzSend(dstChainId, remoteRouter, _payload, params.refundAddress, address(0), adapterParams, msg.value);
        } else if (channel == Message.Channel.WORMHOLE) {
            bytes32 remoteRouter = wormholeState.routers[dstChainId];
            _whSend(dstChainId, remoteRouter.bytes32ToAddress(), _msgSender(), DEFAULT_GAS_LIMIT, 0, _payload);
        } else {
            revert UnsupportedAction();
        }

        emit RemoteTransfer(dstChainId, to, from, value);
    }

    function _receiveTransfer(uint16 _srcChainId, bytes memory _payload) internal {
        (bytes32 _to, uint64 _amount) = _payload.decodeTransfer();
        address to = _to.bytes32ToAddress();
        uint256 amount = _deNormalizeAmount(_amount);

        _mint(to, amount);

        emit RemoteTransferReceived(_srcChainId, to, amount);
    }

    function _receiveTransferWithCallback(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload,
        Message.Channel _channel
    )
        internal
    {
        (bytes32 _from, bytes32 to, uint64 amount, uint64 gasForCallback, bytes memory payload) =
            _payload.decodeTransferWithCallback();

        uint256 denormalizedAmount = _deNormalizeAmount(amount);
        address _to = to.bytes32ToAddress();

        if (!_isContract(_to)) {
            emit NotContractAccount(_to);
            return;
        }

        if (_channel == Message.Channel.LAYERZERO) {
            _receiveLzTransferWithCallback(
                _srcChainId, _srcAddress, _nonce, _from, _to, denormalizedAmount, gasForCallback, payload
            );
        } else if (_channel == Message.Channel.WORMHOLE) {
            _receiveWhTransferWithCallback(
                _srcChainId, _srcAddress, _nonce, _from, _to, denormalizedAmount, gasForCallback, payload
            );
        }
    }

    function _isContract(address to) internal view returns (bool) {
        return to.code.length > 0;
    }

    function _nonblockingLzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload
    )
        internal
        override
    {
        uint8 action = _payload.payloadId();

        if (action == Message.TRANSFER) {
            _receiveTransfer(_srcChainId, _payload);
        } else if (action == Message.TRANSFER_WITH_CALLBACK) {
            _receiveTransferWithCallback(_srcChainId, _srcAddress, _nonce, _payload, Message.Channel.LAYERZERO);
        } else {
            revert UnsupportedAction();
        }
    }

    function _receiveLzTransferWithCallback(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes32 _from,
        address _to,
        uint256 _amount,
        uint64 _gasForCallback,
        bytes memory _payload
    )
        internal
    {
        bool minted = lzState.minted[_srcChainId][_srcAddress][_nonce];
        if (!minted) {
            _mint(address(this), _amount);
            lzState.minted[_srcChainId][_srcAddress][_nonce] = true;
        }

        uint256 gas = minted ? gasleft() : _gasForCallback;
        (bool success, bytes memory reason) = address(this).excessivelySafeCall(
            gasleft(),
            150,
            abi.encodeWithSelector(
                this.tryCallback.selector, _srcChainId, _srcAddress, _nonce, _from, _to, _amount, gas, _payload
            )
        );

        if (!success) {
            _storeFailedMessage(_srcChainId, _srcAddress, _nonce, _payload, reason);
        }
    }

    function _receiveWhTransferWithCallback(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes32 _from,
        address _to,
        uint256 _amount,
        uint64 _gasForCallback,
        bytes memory _payload
    )
        internal
    {
        _mint(address(this), _amount);
        (bool success,) = address(this).excessivelySafeCall(
            gasleft(),
            150,
            abi.encodeWithSelector(
                this.tryCallback.selector,
                _srcChainId,
                _srcAddress,
                _nonce,
                _from,
                _to,
                _amount,
                _gasForCallback,
                _payload
            )
        );

        if (!success) {
            // try Refund to the source
            AdapterCallParams memory params =
                AdapterCallParams({ refundAddress: payable(address(this)), adapter: uint8(Message.Channel.WORMHOLE) });
            _remoteTransfer(_srcChainId, address(this), _from, _amount, params);
        }
    }

    function _wormholeReceive(
        bytes memory _payload,
        bytes32 _srcAddress,
        uint16 _srcChainId,
        bytes32 /*_deliveryHash*/
    )
        internal
        override
    {
        uint8 action = _payload.payloadId();

        if (action == Message.TRANSFER) {
            _receiveTransfer(_srcChainId, _payload);
        } else if (action == Message.TRANSFER_WITH_CALLBACK) {
            _receiveTransferWithCallback(
                _srcChainId, abi.encodePacked(_srcAddress), 0, _payload, Message.Channel.WORMHOLE
            );
        } else {
            revert UnsupportedAction();
        }
    }
}
