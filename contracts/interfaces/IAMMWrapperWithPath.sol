// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0;
pragma abicoder v2;

import "./IAMMWrapper.sol";
import "../utils/AMMLibEIP712.sol";
import "../utils/SpenderLibEIP712.sol";

// Group the local variables together to prevent
// Compiler error: Stack too deep, try removing local variables.
struct GroupedVars {
    SpenderLibEIP712.SpendWithPermit _spendTakerAssetToAMM;
    bytes _spendTakerAssetToAMMSig;
    bytes _makerSpecificData;
}

interface IAMMWrapperWithPath is IAMMWrapper {
    function trade(
        AMMLibEIP712.Order calldata _order,
        uint256 _feeFactor,
        bytes calldata _sig,
        GroupedVars calldata _groupedVars,
        address[] calldata _path
    ) external payable returns (uint256);
}
