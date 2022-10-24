// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0;
pragma abicoder v2;

import "./IStrategyBase.sol";
import "../utils/AMMLibEIP712.sol";
import "../utils/SpenderLibEIP712.sol";

interface IAMMWrapper is IStrategyBase {
    // Operator events
    event SetDefaultFeeFactor(uint16 newDefaultFeeFactor);
    event SetFeeCollector(address newFeeCollector);

    event Swapped(
        string source,
        bytes32 indexed transactionHash,
        address indexed userAddr,
        bool relayed,
        address takerAssetAddr,
        uint256 takerAssetAmount,
        address makerAddr,
        address makerAssetAddr,
        uint256 makerAssetAmount,
        address receiverAddr,
        uint256 settleAmount,
        uint16 feeFactor
    );

    // Group the local variables together to prevent
    // Compiler error: Stack too deep, try removing local variables.
    struct TxMetaData {
        string source;
        bytes32 transactionHash;
        uint256 settleAmount;
        uint256 receivedAmount;
        uint16 feeFactor;
        bool relayed;
    }

    function trade(
        AMMLibEIP712.Order memory _order,
        SpenderLibEIP712.SpendWithPermit memory _spendTakerAssetToAMM,
        uint256 _feeFactor,
        bytes memory _sig,
        bytes memory _spendTakerAssetToAMMSig
    ) external payable returns (uint256);
}
