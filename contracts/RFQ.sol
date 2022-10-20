// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IRFQ.sol";
import "./utils/StrategyBase.sol";
import "./utils/RFQLibEIP712.sol";
import "./utils/BaseLibEIP712.sol";
import "./utils/SpenderLibEIP712.sol";
import "./utils/SignatureValidator.sol";
import "./utils/LibConstant.sol";

import "forge-std/console2.sol";

contract RFQ is IRFQ, StrategyBase, ReentrancyGuard, SignatureValidator, BaseLibEIP712 {
    using SafeMath for uint256;
    using Address for address;

    // Constants do not have storage slot.
    string public constant SOURCE = "RFQ v1";

    // Below are the variables which consume storage slots.
    address public feeCollector;

    struct GroupedVars {
        bytes32 orderHash;
        bytes32 transactionHash;
    }

    // Operator events
    event SetFeeCollector(address newFeeCollector);

    event FillOrder(
        string source,
        bytes32 indexed transactionHash,
        bytes32 indexed orderHash,
        address indexed userAddr,
        address takerAssetAddr,
        uint256 takerAssetAmount,
        address makerAddr,
        address makerAssetAddr,
        uint256 makerAssetAmount,
        address receiverAddr,
        uint256 settleAmount,
        uint16 feeFactor
    );

    receive() external payable {}

    /************************************************************
     *              Constructor and init functions               *
     *************************************************************/
    constructor(
        address _owner,
        address _userProxy,
        address _weth,
        address _permStorage,
        address _spender,
        address _feeCollector
    ) StrategyBase(_owner, _userProxy, _weth, _permStorage, _spender) {
        feeCollector = _feeCollector;
    }

    /************************************************************
     *           Management functions for Operator               *
     *************************************************************/
    /**
     * @dev set fee collector
     */
    function setFeeCollector(address _newFeeCollector) external onlyOwner {
        require(_newFeeCollector != address(0), "RFQ: fee collector can not be zero address");
        feeCollector = _newFeeCollector;

        emit SetFeeCollector(_newFeeCollector);
    }

    /************************************************************
     *                   External functions                      *
     *************************************************************/
    function fill(
        RFQLibEIP712.Order calldata _order,
        SpenderLibEIP712.SpendWithPermit calldata _spendMakerAssetToReceiver,
        SpenderLibEIP712.SpendWithPermit calldata _spendTakerAssetToMaker,
        bytes calldata _mmSignature,
        bytes calldata _userSignature,
        bytes calldata _spendMakerAssetToReceiverSig,
        bytes calldata _spendTakerAssetToMakerSig
    ) external payable override nonReentrant onlyUserProxy returns (uint256) {
        // check the order deadline and fee factor
        require(_order.deadline >= block.timestamp, "RFQ: expired order");
        require(_order.feeFactor < LibConstant.BPS_MAX, "RFQ: invalid fee factor");

        // check the spender deadline and RFQ address
        require(_spendMakerAssetToReceiver.expiry >= block.timestamp, "RFQ: expired maker spender");
        require(_spendMakerAssetToReceiver.requester == address(this), "RFQ: invalid RFQ address");
        require(_spendTakerAssetToMaker.expiry >= block.timestamp, "RFQ: expired taker spender");
        require(_spendTakerAssetToMaker.requester == address(this), "RFQ: invalid RFQ address");

        GroupedVars memory vars;

        // Validate signatures
        vars.orderHash = RFQLibEIP712._getOrderHash(_order);
        require(isValidSignature(_order.makerAddr, getEIP712Hash(vars.orderHash), bytes(""), _mmSignature), "RFQ: invalid MM signature");
        vars.transactionHash = RFQLibEIP712._getTransactionHash(_order);
        require(isValidSignature(_order.takerAddr, getEIP712Hash(vars.transactionHash), bytes(""), _userSignature), "RFQ: invalid user signature");

        console2.logString("---------- Order ----------");
        console2.logAddress(_order.takerAddr);
        console2.logAddress(_order.makerAddr);
        console2.logAddress(_order.takerAssetAddr);
        console2.logAddress(_order.makerAssetAddr);
        console2.logUint(_order.takerAssetAmount);
        console2.logUint(_order.makerAssetAmount);
        console2.logAddress(_order.receiverAddr);
        console2.logUint(_order.salt);
        console2.logUint(_order.deadline);
        console2.logUint(_order.feeFactor);
        console2.logString("---------- MakerSpend ----------");
        console2.logAddress(_spendMakerAssetToReceiver.tokenAddr);
        console2.logAddress(_spendMakerAssetToReceiver.requester);
        console2.logAddress(_spendMakerAssetToReceiver.user);
        console2.logAddress(_spendMakerAssetToReceiver.recipient);
        console2.logUint(_spendMakerAssetToReceiver.amount);
        console2.logUint(_spendMakerAssetToReceiver.salt);
        console2.logUint(_spendMakerAssetToReceiver.expiry);
        console2.logBytes(_spendMakerAssetToReceiverSig);
        console2.logString("---------- UserSpend ----------");
        console2.logAddress(_spendTakerAssetToMaker.tokenAddr);
        console2.logAddress(_spendTakerAssetToMaker.requester);
        console2.logAddress(_spendTakerAssetToMaker.user);
        console2.logAddress(_spendTakerAssetToMaker.recipient);
        console2.logUint(_spendTakerAssetToMaker.amount);
        console2.logUint(_spendTakerAssetToMaker.salt);
        console2.logUint(_spendTakerAssetToMaker.expiry);
        console2.logBytes(_spendTakerAssetToMakerSig);
        console2.logString("---------- RFQ ----------");
        console2.logAddress(address(this));
        console2.logAddress(msg.sender);
        console2.logAddress(payable(msg.sender));
        console2.logString("---------- Sign User ----------");
        console2.logAddress(_spendMakerAssetToReceiver.user);
        console2.logAddress(_spendTakerAssetToMaker.user);

        // require(isValidSignature(_mmSpend.user, getEIP712Hash(vars.orderSpendHash), bytes(""), _mmSpendSignature), "RFQ: invalid MM spend signature");
        // require(
        //     isValidSignature(_userSpend.user, getEIP712Hash(vars.transactionSpendHash), bytes(""), _userSpendSignature),
        //     "RFQ: invalid user spend signature"
        // );

        // Set transaction as seen, PermanentStorage would throw error if transaction already seen.
        permStorage.setRFQTransactionSeen(vars.transactionHash);

        return _settle(_order, _spendMakerAssetToReceiver, _spendTakerAssetToMaker, vars, _spendMakerAssetToReceiverSig, _spendTakerAssetToMakerSig);
    }

    function _emitFillOrder(
        RFQLibEIP712.Order memory _order,
        GroupedVars memory _vars,
        uint256 settleAmount
    ) internal {
        emit FillOrder(
            SOURCE,
            _vars.transactionHash,
            _vars.orderHash,
            _order.takerAddr,
            _order.takerAssetAddr,
            _order.takerAssetAmount,
            _order.makerAddr,
            _order.makerAssetAddr,
            _order.makerAssetAmount,
            _order.receiverAddr,
            settleAmount,
            uint16(_order.feeFactor)
        );
    }

    // settle
    function _settle(
        RFQLibEIP712.Order memory _order,
        SpenderLibEIP712.SpendWithPermit memory _spendMakerAssetToReceiver,
        SpenderLibEIP712.SpendWithPermit memory _spendTakerAssetToMaker,
        GroupedVars memory _vars,
        bytes memory _spendMakerAssetToReceiverSig,
        bytes memory _spendTakerAssetToMakerSig
    ) internal returns (uint256) {
        // Transfer taker asset to maker
        if (address(weth) == _order.takerAssetAddr) {
            // Deposit to WETH if taker asset is ETH
            require(msg.value == _order.takerAssetAmount, "RFQ: insufficient ETH");
            weth.deposit{ value: msg.value }();
            weth.transfer(_order.makerAddr, _order.takerAssetAmount);
        } else {
            // spender.spendFromUserTo({
            //     _user: _order.takerAddr,
            //     _tokenAddr: _order.takerAssetAddr,
            //     _receiverAddr: _order.makerAddr,
            //     _amount: _order.takerAssetAmount
            // });
            console2.logString("---------- Sit A ----------");
            console2.logAddress(address(msg.sender));
            // Confirm that
            // 'takerAddr' sends 'takerAssetAmount' amount of 'takerAssetAddr' to 'makerAddr'
            require(
                _order.takerAddr == _spendTakerAssetToMaker.user &&
                    _order.takerAssetAddr == _spendTakerAssetToMaker.tokenAddr &&
                    _order.makerAddr == _spendTakerAssetToMaker.recipient &&
                    _order.takerAssetAmount == _spendTakerAssetToMaker.amount,
                "RFQ: taker spender information is incorrect"
            );
            spender.spendFromUserToWithPermit({
                _tokenAddr: _spendTakerAssetToMaker.tokenAddr,
                _requester: _spendTakerAssetToMaker.requester,
                _user: _spendTakerAssetToMaker.user,
                _recipient: _spendTakerAssetToMaker.recipient,
                _amount: _spendTakerAssetToMaker.amount,
                _salt: _spendTakerAssetToMaker.salt,
                _expiry: _spendTakerAssetToMaker.expiry,
                _spendWithPermitSig: _spendTakerAssetToMakerSig
            });
        }

        // Transfer maker asset to taker, sub fee
        uint256 fee = _order.makerAssetAmount.mul(_order.feeFactor).div(LibConstant.BPS_MAX);
        uint256 settleAmount = _order.makerAssetAmount;
        if (fee > 0) {
            settleAmount = settleAmount.sub(fee);
        }

        // Transfer token/Eth to receiver
        if (_order.makerAssetAddr == address(weth)) {
            // Transfer from maker
            spender.spendFromUser(_order.makerAddr, _order.makerAssetAddr, settleAmount);
            console2.logString("---------- Sit B ----------");
            // Confirm that
            // 'makerAddr' sends 'settleAmount' amount of 'makerAssetAddr' to 'msg.sender'

            weth.withdraw(settleAmount);
            payable(_order.receiverAddr).transfer(settleAmount);
        } else {
            // spender.spendFromUserTo(_order.makerAddr, _order.makerAssetAddr, _order.receiverAddr, settleAmount);
            console2.logString("---------- Sit C ----------");
            // Confirm that
            // 'makerAddr' sends 'settleAmount' amount of 'makerAssetAddr' to 'receiverAddr'
            require(
                _order.makerAddr == _spendMakerAssetToReceiver.user &&
                    _order.makerAssetAddr == _spendMakerAssetToReceiver.tokenAddr &&
                    _order.receiverAddr == _spendMakerAssetToReceiver.recipient &&
                    settleAmount == _spendMakerAssetToReceiver.amount,
                "RFQ: maker spender information is incorrect"
            );
            spender.spendFromUserToWithPermit({
                _tokenAddr: _spendMakerAssetToReceiver.tokenAddr,
                _requester: _spendMakerAssetToReceiver.requester,
                _user: _spendMakerAssetToReceiver.user,
                _recipient: _spendMakerAssetToReceiver.recipient,
                _amount: _spendMakerAssetToReceiver.amount,
                _salt: _spendMakerAssetToReceiver.salt,
                _expiry: _spendMakerAssetToReceiver.expiry,
                _spendWithPermitSig: _spendMakerAssetToReceiverSig
            });
        }
        // Collect fee
        if (fee > 0) {
            spender.spendFromUserTo(_order.makerAddr, _order.makerAssetAddr, feeCollector, fee);
            console2.logString("---------- Sit D ----------");
        }

        _emitFillOrder(_order, _vars, settleAmount);

        return settleAmount;
    }
}
