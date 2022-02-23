// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./IBancorNetwork.sol";
import "./IConversionPathFinder.sol";
import "./converter/interfaces/IConverter.sol";
import "./converter/interfaces/IConverterAnchor.sol";
import "./utility/ContractRegistryClient.sol";
import "./utility/TokenHolder.sol";

import "./token/interfaces/IDSToken.sol";
import "./token/SafeERC20Ex.sol";
import "./token/ReserveToken.sol";

import "./bancorx/interfaces/IBancorX.sol";

// interface of older converters for backward compatibility
interface ILegacyConverter {
    function change(
        IReserveToken sourceToken,
        IReserveToken targetToken,
        uint256 sourceAmount,
        uint256 minReturn
    ) external returns (uint256);
}


contract BancorNetwork is IBancorNetwork, TokenHolder, ContractRegistryClient, ReentrancyGuard {
    using SafeMath for uint256;
    using ReserveToken for IReserveToken;
    using SafeERC20 for IERC20;
    using SafeERC20Ex for IERC20;

    struct ConversionStep {
        IConverter converter;
        IConverterAnchor anchor;
        IReserveToken sourceToken;
        IReserveToken targetToken;
        address payable beneficiary;
        bool isV28OrHigherConverter;
    }


    event Conversion(
        IConverterAnchor indexed anchor,
        IReserveToken indexed sourceToken,
        IReserveToken indexed targetToken,
        uint256 sourceAmount,
        uint256 targetAmount,
        address trader
    );
]
    function conversionPath(IReserveToken sourceToken, IReserveToken targetToken)
        public
        view
        returns (address[] memory)
    {
        IConversionPathFinder pathFinder = IConversionPathFinder(_addressOf(CONVERSION_PATH_FINDER));
        return pathFinder.findPath(sourceToken, targetToken);
    }

    function rateByPath(address[] memory path, uint256 sourceAmount) public view override returns (uint256) {
        // verify that the number of elements is larger than 2 and odd
        require(path.length > 2 && path.length % 2 == 1, "ERR_INVALID_PATH");

        uint256 amount = sourceAmount;

        // iterate over the conversion path
        for (uint256 i = 2; i < path.length; i += 2) {
            IReserveToken sourceToken = IReserveToken(path[i - 2]);
            address anchor = path[i - 1];
            IReserveToken targetToken = IReserveToken(path[i]);
            IConverter converter = IConverter(payable(IConverterAnchor(anchor).owner()));
            (amount, ) = _getReturn(converter, sourceToken, targetToken, amount);
        }

        return amount;
    }


    function convertByPath2(
        address[] memory path,
        uint256 sourceAmount,
        uint256 minReturn,
        address payable beneficiary
    ) public payable nonReentrant greaterThanZero(minReturn) returns (uint256) {
        // verify that the path contains at least a single 'hop' and that the number of elements is odd
        require(path.length > 2 && path.length % 2 == 1, "ERR_INVALID_PATH");

        // validate msg.value and prepare the source token for the conversion
        _handleSourceToken(IReserveToken(path[0]), IConverterAnchor(path[1]), sourceAmount);

        // check if beneficiary is set
        if (beneficiary == address(0)) {
            beneficiary = msg.sender;
        }

        // convert and get the resulting amount
        ConversionStep[] memory data = _createConversionData(path, beneficiary);
        uint256 amount = _doConversion(data, sourceAmount, minReturn);

        // handle the conversion target tokens
        _handleTargetToken(data, amount, beneficiary);

        return amount;
    }


    function xConvert(
        address[] memory path,
        uint256 sourceAmount,
        uint256 minReturn,
        bytes32 targetBlockchain,
        bytes32 targetAccount,
        uint256 conversionId
    ) public payable greaterThanZero(minReturn) returns (uint256) {
        IReserveToken targetToken = IReserveToken(path[path.length - 1]);
        IBancorX bancorX = IBancorX(_addressOf(BANCOR_X));

        // verify that the destination token is BNT
        require(targetToken == IReserveToken(_addressOf(BNT_TOKEN)), "ERR_INVALID_TARGET_TOKEN");

        // convert and get the resulting amount
        uint256 amount = convertByPath2(path, sourceAmount, minReturn, payable(address(this)));

        // grant BancorX allowance
        targetToken.ensureApprove(address(bancorX), amount);

        // transfer the resulting amount to BancorX
        bancorX.xTransfer(targetBlockchain, targetAccount, amount, conversionId);

        return amount;
    }


    function completeXConversion(
        address[] memory path,
        IBancorX bancorX,
        uint256 conversionId,
        uint256 minReturn,
        address payable beneficiary
    ) public returns (uint256) {
        // verify that the source token is the BancorX token
        require(path[0] == address(bancorX.token()), "ERR_INVALID_SOURCE_TOKEN");

        // get conversion amount from BancorX contract
        uint256 amount = bancorX.getXTransferAmount(conversionId, msg.sender);

        // perform the conversion
        return convertByPath2(path, amount, minReturn, beneficiary);
    }

    function _doConversion(
        ConversionStep[] memory data,
        uint256 sourceAmount,
        uint256 minReturn
    ) private returns (uint256) {
        uint256 targetAmount;

        // iterate over the conversion data
        for (uint256 i = 0; i < data.length; i++) {
            ConversionStep memory stepData = data[i];

            // newer converter
            if (stepData.isV28OrHigherConverter) {
                // transfer the tokens to the converter only if the network contract currently holds the tokens
                // not needed with ETH or if it's the first conversion step
                if (i != 0 && data[i - 1].beneficiary == address(this) && !stepData.sourceToken.isNativeToken()) {
                    stepData.sourceToken.safeTransfer(address(stepData.converter), sourceAmount);
                }
            } else {
                assert(address(stepData.sourceToken) != address(stepData.anchor));
                // grant allowance for it to transfer the tokens from the network contract
                stepData.sourceToken.ensureApprove(address(stepData.converter), sourceAmount);
            }

            // do the conversion
            if (!stepData.isV28OrHigherConverter) {
                targetAmount = ILegacyConverter(address(stepData.converter)).change(
                    stepData.sourceToken,
                    stepData.targetToken,
                    sourceAmount,
                    1
                );
            } else if (stepData.sourceToken.isNativeToken()) {
                targetAmount = stepData.converter.convert{ value: msg.value }(
                    stepData.sourceToken,
                    stepData.targetToken,
                    sourceAmount,
                    msg.sender,
                    stepData.beneficiary
                );
            } else {
                targetAmount = stepData.converter.convert(
                    stepData.sourceToken,
                    stepData.targetToken,
                    sourceAmount,
                    msg.sender,
                    stepData.beneficiary
                );
            }

            emit Conversion(
                stepData.anchor,
                stepData.sourceToken,
                stepData.targetToken,
                sourceAmount,
                targetAmount,
                msg.sender
            );
            sourceAmount = targetAmount;
        }

        // ensure the trade meets the minimum requested amount
        require(targetAmount >= minReturn, "ERR_RETURN_TOO_LOW");

        return targetAmount;
    }

    function _handleSourceToken(
        IReserveToken sourceToken,
        IConverterAnchor anchor,
        uint256 sourceAmount
    ) private {
        IConverter firstConverter = IConverter(payable(anchor.owner()));
        bool isNewerConverter = _isV28OrHigherConverter(firstConverter);

        if (msg.value > 0) {
            require(msg.value == sourceAmount, "ERR_ETH_AMOUNT_MISMATCH");
            require(sourceToken.isNativeToken(), "ERR_INVALID_SOURCE_TOKEN");
            require(isNewerConverter, "ERR_CONVERTER_NOT_SUPPORTED");
        } else {
            require(!sourceToken.isNativeToken(), "ERR_INVALID_SOURCE_TOKEN");
            if (isNewerConverter) {
                // newer converter - transfer the tokens from the sender directly to the converter
                sourceToken.safeTransferFrom(msg.sender, address(firstConverter), sourceAmount);
            } else {
                // otherwise claim the tokens
                sourceToken.safeTransferFrom(msg.sender, address(this), sourceAmount);
            }
        }
    }

    function _handleTargetToken(
        ConversionStep[] memory data,
        uint256 targetAmount,
        address payable beneficiary
    ) private {
        ConversionStep memory stepData = data[data.length - 1];

        // network contract doesn't hold the tokens, do nothing
        if (stepData.beneficiary != address(this)) {
            return;
        }

        IReserveToken targetToken = stepData.targetToken;
        assert(!targetToken.isNativeToken());
        targetToken.safeTransfer(beneficiary, targetAmount);
    }

    function _createConversionData(address[] memory path, address payable beneficiary)
        private
        view
        returns (ConversionStep[] memory)
    {
        ConversionStep[] memory data = new ConversionStep[](path.length / 2);

        // iterate the conversion path and create the conversion data for each step
        uint256 i;
        for (i = 0; i < path.length - 1; i += 2) {
            IConverterAnchor anchor = IConverterAnchor(path[i + 1]);
            IConverter converter = IConverter(payable(anchor.owner()));
            IReserveToken targetToken = IReserveToken(path[i + 2]);

            data[i / 2] = ConversionStep({ // set the converter anchor
                anchor: anchor, // set the converter
                converter: converter, // set the source/target tokens
                sourceToken: IReserveToken(path[i]),
                targetToken: targetToken, // requires knowledge about the next step, so initialize in the next phase
                beneficiary: address(0), // set flags
                isV28OrHigherConverter: _isV28OrHigherConverter(converter)
            });
        }

        // set the beneficiary for each step
        for (i = 0; i < data.length; i++) {
            ConversionStep memory stepData = data[i];
            // check if the converter in this step is newer as older converters don't even support the beneficiary argument
            if (stepData.isV28OrHigherConverter) {
                if (i == data.length - 1) {
                    // converter in this step is newer, beneficiary is the user input address
                    stepData.beneficiary = beneficiary;
                } else if (data[i + 1].isV28OrHigherConverter) {
                    // the converter in the next step is newer, beneficiary is the next converter
                    stepData.beneficiary = address(data[i + 1].converter);
                } else {
                    // the converter in the next step is older, beneficiary is the network contract
                    stepData.beneficiary = payable(address(this));
                }
            } else {
                // converter in this step is older, beneficiary is the network contract
                stepData.beneficiary = payable(address(this));
            }
        }

        return data;
    }

    bytes4 private constant GET_RETURN_FUNC_SELECTOR = bytes4(keccak256("getReturn(address,address,uint256)"));

    // using a static call to get the return from older converters
    function _getReturn(
        IConverter dest,
        IReserveToken sourceToken,
        IReserveToken targetToken,
        uint256 sourceAmount
    ) internal view returns (uint256, uint256) {
        bytes memory data = abi.encodeWithSelector(GET_RETURN_FUNC_SELECTOR, sourceToken, targetToken, sourceAmount);
        (bool success, bytes memory returnData) = address(dest).staticcall(data);

        if (success) {
            if (returnData.length == 64) {
                return abi.decode(returnData, (uint256, uint256));
            }

            if (returnData.length == 32) {
                return (abi.decode(returnData, (uint256)), 0);
            }
        }

        return (0, 0);
    }

    bytes4 private constant IS_V28_OR_HIGHER_FUNC_SELECTOR = bytes4(keccak256("isV28OrHigher()"));

    // using a static call to identify converter version
    // can't rely on the version number since the function had a different signature in older converters
    function _isV28OrHigherConverter(IConverter converter) internal view returns (bool) {
        bytes memory data = abi.encodeWithSelector(IS_V28_OR_HIGHER_FUNC_SELECTOR);
        (bool success, bytes memory returnData) = address(converter).staticcall{ gas: 4000 }(data);

        if (success && returnData.length == 32) {
            return abi.decode(returnData, (bool));
        }

        return false;
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function getReturnByPath(address[] memory path, uint256 sourceAmount) public view returns (uint256, uint256) {
        return (rateByPath(path, sourceAmount), 0);
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function convertByPath(
        address[] memory path,
        uint256 sourceAmount,
        uint256 minReturn,
        address payable beneficiary,
        address, /* affiliateAccount */
        uint256 /* affiliateFee */
    ) public payable override returns (uint256) {
        return convertByPath2(path, sourceAmount, minReturn, beneficiary);
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function convert(
        address[] memory path,
        uint256 sourceAmount,
        uint256 minReturn
    ) public payable returns (uint256) {
        return convertByPath2(path, sourceAmount, minReturn, address(0));
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function convert2(
        address[] memory path,
        uint256 sourceAmount,
        uint256 minReturn,
        address, /* affiliateAccount */
        uint256 /* affiliateFee */
    ) public payable returns (uint256) {
        return convertByPath2(path, sourceAmount, minReturn, address(0));
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function convertFor(
        address[] memory path,
        uint256 sourceAmount,
        uint256 minReturn,
        address payable beneficiary
    ) public payable returns (uint256) {
        return convertByPath2(path, sourceAmount, minReturn, beneficiary);
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function convertFor2(
        address[] memory path,
        uint256 sourceAmount,
        uint256 minReturn,
        address payable beneficiary,
        address, /* affiliateAccount */
        uint256 /* affiliateFee */
    ) public payable greaterThanZero(minReturn) returns (uint256) {
        return convertByPath2(path, sourceAmount, minReturn, beneficiary);
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function claimAndConvert(
        address[] memory path,
        uint256 sourceAmount,
        uint256 minReturn
    ) public returns (uint256) {
        return convertByPath2(path, sourceAmount, minReturn, address(0));
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function claimAndConvert2(
        address[] memory path,
        uint256 sourceAmount,
        uint256 minReturn,
        address, /* affiliateAccount */
        uint256 /* affiliateFee */
    ) public returns (uint256) {
        return convertByPath2(path, sourceAmount, minReturn, address(0));
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function claimAndConvertFor(
        address[] memory path,
        uint256 sourceAmount,
        uint256 minReturn,
        address payable beneficiary
    ) public returns (uint256) {
        return convertByPath2(path, sourceAmount, minReturn, beneficiary);
    }

    /**
     * @dev deprecated, backward compatibility
     */
    function claimAndConvertFor2(
        address[] memory path,
        uint256 sourceAmount,
        uint256 minReturn,
        address payable beneficiary,
        address, /* affiliateAccount */
        uint256 /* affiliateFee */
    ) public returns (uint256) {
        return convertByPath2(path, sourceAmount, minReturn, beneficiary);
    }
}
