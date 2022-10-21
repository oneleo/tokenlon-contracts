// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
        SpenderLibEIP712.SpendWithPermit spendMakerAssetToReceiver;
        SpenderLibEIP712.SpendWithPermit spendTakerAssetToMaker;
        SpenderLibEIP712.SpendWithPermit spendMakerAssetToMsgSender;
        bytes spendMakerAssetToReceiverSig;
        bytes spendTakerAssetToMakerSig;
        bytes spendMakerAssetToMsgSenderSig;
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
    function fill(FillParams calldata _params) external payable override nonReentrant onlyUserProxy returns (uint256) {
        // check the order deadline and fee factor
        require(_params._order.deadline >= block.timestamp, "RFQ: expired order");
        require(_params._order.feeFactor < LibConstant.BPS_MAX, "RFQ: invalid fee factor");

        // check the spender deadline and RFQ address
        require(_params._spendMakerAssetToReceiver.expiry >= block.timestamp, "RFQ: expired maker spender");
        require(_params._spendMakerAssetToReceiver.requester == address(this), "RFQ: invalid RFQ address");
        require(_params._spendTakerAssetToMaker.expiry >= block.timestamp, "RFQ: expired taker spender");
        require(_params._spendTakerAssetToMaker.requester == address(this), "RFQ: invalid RFQ address");

        GroupedVars memory vars;

        // Validate signatures
        vars.orderHash = RFQLibEIP712._getOrderHash(_params._order);
        require(isValidSignature(_params._order.makerAddr, getEIP712Hash(vars.orderHash), bytes(""), _params._mmSignature), "RFQ: invalid MM signature");
        vars.transactionHash = RFQLibEIP712._getTransactionHash(_params._order);
        require(
            isValidSignature(_params._order.takerAddr, getEIP712Hash(vars.transactionHash), bytes(""), _params._userSignature),
            "RFQ: invalid user signature"
        );

        vars.spendMakerAssetToReceiver = _params._spendMakerAssetToReceiver;
        vars.spendTakerAssetToMaker = _params._spendTakerAssetToMaker;
        // vars.spendMakerAssetToMsgSender = _params._spendMakerAssetToMsgSender;
        vars.spendMakerAssetToReceiverSig = _params._spendMakerAssetToReceiverSig;
        vars.spendTakerAssetToMakerSig = _params._spendTakerAssetToMakerSig;
        // vars.spendMakerAssetToMsgSenderSig = _params._spendMakerAssetToMsgSenderSig;

        console2.logString("---------- Order ----------");
        console2.logAddress(_params._order.takerAddr);
        console2.logAddress(_params._order.makerAddr);
        console2.logAddress(_params._order.takerAssetAddr);
        console2.logAddress(_params._order.makerAssetAddr);
        console2.logUint(_params._order.takerAssetAmount);
        console2.logUint(_params._order.makerAssetAmount);
        console2.logAddress(_params._order.receiverAddr);
        console2.logUint(_params._order.salt);
        console2.logUint(_params._order.deadline);
        console2.logUint(_params._order.feeFactor);
        console2.logString("---------- MakerSpend ----------");
        console2.logAddress(_params._spendMakerAssetToReceiver.tokenAddr);
        console2.logAddress(_params._spendMakerAssetToReceiver.requester);
        console2.logAddress(_params._spendMakerAssetToReceiver.user);
        console2.logAddress(_params._spendMakerAssetToReceiver.recipient);
        console2.logUint(_params._spendMakerAssetToReceiver.amount);
        console2.logUint(_params._spendMakerAssetToReceiver.salt);
        console2.logUint(_params._spendMakerAssetToReceiver.expiry);
        console2.logBytes(_params._spendMakerAssetToReceiverSig);
        console2.logString("---------- UserSpend ----------");
        console2.logAddress(_params._spendTakerAssetToMaker.tokenAddr);
        console2.logAddress(_params._spendTakerAssetToMaker.requester);
        console2.logAddress(_params._spendTakerAssetToMaker.user);
        console2.logAddress(_params._spendTakerAssetToMaker.recipient);
        console2.logUint(_params._spendTakerAssetToMaker.amount);
        console2.logUint(_params._spendTakerAssetToMaker.salt);
        console2.logUint(_params._spendTakerAssetToMaker.expiry);
        console2.logBytes(_params._spendTakerAssetToMakerSig);
        console2.logString("---------- RFQ ----------");
        console2.logAddress(address(this));
        console2.logAddress(msg.sender);
        console2.logAddress(payable(msg.sender));
        console2.logString("---------- Sign User ----------");
        console2.logAddress(_params._spendMakerAssetToReceiver.user);
        console2.logAddress(_params._spendTakerAssetToMaker.user);

        // require(isValidSignature(_mmSpend.user, getEIP712Hash(vars.orderSpendHash), bytes(""), _mmSpendSignature), "RFQ: invalid MM spend signature");
        // require(
        //     isValidSignature(_userSpend.user, getEIP712Hash(vars.transactionSpendHash), bytes(""), _userSpendSignature),
        //     "RFQ: invalid user spend signature"
        // );

        // Set transaction as seen, PermanentStorage would throw error if transaction already seen.
        permStorage.setRFQTransactionSeen(vars.transactionHash);

        return _settle(_params._order, vars);
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
    function _settle(RFQLibEIP712.Order memory _order, GroupedVars memory _vars) internal returns (uint256) {
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
                _order.takerAddr == _vars.spendTakerAssetToMaker.user &&
                    _order.takerAssetAddr == _vars.spendTakerAssetToMaker.tokenAddr &&
                    _order.makerAddr == _vars.spendTakerAssetToMaker.recipient &&
                    _order.takerAssetAmount == _vars.spendTakerAssetToMaker.amount,
                "RFQ: taker spender information is incorrect"
            );
            spender.spendFromUserToWithPermit({
                _tokenAddr: _vars.spendTakerAssetToMaker.tokenAddr,
                _requester: _vars.spendTakerAssetToMaker.requester,
                _user: _vars.spendTakerAssetToMaker.user,
                _recipient: _vars.spendTakerAssetToMaker.recipient,
                _amount: _vars.spendTakerAssetToMaker.amount,
                _salt: _vars.spendTakerAssetToMaker.salt,
                _expiry: _vars.spendTakerAssetToMaker.expiry,
                _spendWithPermitSig: _vars.spendTakerAssetToMakerSig
            });
            // IERC20(_tokenAddr).transfer(_order.makerAddr, _order.takerAssetAmount);
            // weth.deposit{ value: msg.value }();
            // weth.transfer(_order.makerAddr, _order.takerAssetAmount);
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
            // spender.spendFromUserToWithPermit({
            //     _tokenAddr: _vars.spendMakerAssetToMsgSender.tokenAddr,
            //     _requester: _vars.spendMakerAssetToMsgSender.requester,
            //     _user: _vars.spendMakerAssetToMsgSender.user,
            //     _recipient: _vars.spendMakerAssetToMsgSender.recipient,
            //     _amount: _vars.spendMakerAssetToMsgSender.amount,
            //     _salt: _vars.spendMakerAssetToMsgSender.salt,
            //     _expiry: _vars.spendMakerAssetToMsgSender.expiry,
            //     _spendWithPermitSig: _vars.spendMakerAssetToMsgSenderSig
            // });
            weth.withdraw(settleAmount);
            payable(_order.receiverAddr).transfer(settleAmount);
        } else {
            // spender.spendFromUserTo(_order.makerAddr, _order.makerAssetAddr, _order.receiverAddr, settleAmount);
            console2.logString("---------- Sit C ----------");
            // Confirm that
            // 'makerAddr' sends 'settleAmount' amount of 'makerAssetAddr' to 'receiverAddr'
            require(
                _order.makerAddr == _vars.spendMakerAssetToReceiver.user &&
                    _order.makerAssetAddr == _vars.spendMakerAssetToReceiver.tokenAddr &&
                    _order.receiverAddr == _vars.spendMakerAssetToReceiver.recipient &&
                    settleAmount == _vars.spendMakerAssetToReceiver.amount,
                "RFQ: maker spender information is incorrect"
            );
            spender.spendFromUserToWithPermit({
                _tokenAddr: _vars.spendMakerAssetToReceiver.tokenAddr,
                _requester: _vars.spendMakerAssetToReceiver.requester,
                _user: _vars.spendMakerAssetToReceiver.user,
                _recipient: _vars.spendMakerAssetToReceiver.recipient,
                _amount: _vars.spendMakerAssetToReceiver.amount,
                _salt: _vars.spendMakerAssetToReceiver.salt,
                _expiry: _vars.spendMakerAssetToReceiver.expiry,
                _spendWithPermitSig: _vars.spendMakerAssetToReceiverSig
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
