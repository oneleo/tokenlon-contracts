// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0;
pragma abicoder v2;

import "./IStrategyBase.sol";
import "../utils/RFQLibEIP712.sol";
import "../utils/SpenderLibEIP712.sol";

struct FillParams {
    RFQLibEIP712.Order _order;
    SpenderLibEIP712.SpendWithPermit _spendMakerAssetToReceiver;
    SpenderLibEIP712.SpendWithPermit _spendTakerAssetToMaker;
    // SpenderLibEIP712.SpendWithPermit _spendMakerAssetToMsgSender;
    bytes _mmSignature;
    bytes _userSignature;
    bytes _spendMakerAssetToReceiverSig;
    bytes _spendTakerAssetToMakerSig;
    // bytes _spendMakerAssetToMsgSenderSig;
}

interface IRFQ is IStrategyBase {
    function fill(FillParams calldata _params) external payable returns (uint256);
}
