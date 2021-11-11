/*
    Copyright 2021 Set Labs Inc.

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

    SPDX-License-Identifier: Apache License, Version 2.0
*/

pragma solidity 0.6.10;
pragma experimental "ABIEncoderV2";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { FixedPoint96 } from "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import { FullMath } from "@uniswap/v3-core/contracts/libraries/FullMath.sol";


import { PerpV2 } from "../integration/lib/PerpV2.sol";
import { IAccountBalance } from "../../interfaces/external/perp-v2/IAccountBalance.sol";
import { IClearingHouse } from "../../interfaces/external/perp-v2/IClearingHouse.sol";
import { IExchange } from "../../interfaces/external/perp-v2/IExchange.sol";
import { IVault } from "../../interfaces/external/perp-v2/IVault.sol";
import { IQuoter } from "../../interfaces/external/perp-v2/IQuoter.sol";
import { IController } from "../../interfaces/IController.sol";
import { IDebtIssuanceModule } from "../../interfaces/IDebtIssuanceModule.sol";
import { IModuleIssuanceHook } from "../../interfaces/IModuleIssuanceHook.sol";
import { ISetToken } from "../../interfaces/ISetToken.sol";
import { ModuleBase } from "../lib/ModuleBase.sol";
import { PreciseUnitMath } from "../../lib/PreciseUnitMath.sol";
import { AddressArrayUtils } from "../../lib/AddressArrayUtils.sol";

// TODO: REMOVE THIS WHEN COMPLETE
import "hardhat/console.sol";

/**
 * @title PerpLeverageModule
 * @author Set Protocol
 * @notice Smart contract that enables leveraged trading using the PerpV2 protocol. Each
 * SetToken can only manage a single Perp account, represented as a positive equity external position
 * whose value is the net Perp account value denominated in the collateral token deposited into the Perp Protocol.
 */
contract PerpV2LeverageModule is ModuleBase, ReentrancyGuard, Ownable, IModuleIssuanceHook {
    using PerpV2 for ISetToken;
    using PreciseUnitMath for int256;
    using AddressArrayUtils for address[];

    /* ============ Structs ============ */

    struct ActionInfo {
        ISetToken setToken;
        address baseToken;              // Virtual token minted by the Perp protocol
        bool isBaseToQuote;             // When true, `baseToken` is being sold, when false, bought
        bool isExactInput;              // When true, `amount` is the swap input, when false, the swap output
        int256 amount;                  // Quantity in 10**18 decimals
        uint256 oppositeAmountBound;    // vUSDC receive quantity bound (see `_createAndValidateActionInfoNotional` for details)
    }

    struct PositionInfo {
        address baseToken;              // Virtual token minted by the Perp protocol
        int256 baseBalance;             // Position size in 10**18 decimals. When negative, position is short
        int256 quoteBalance;            // vUSDC "debt" minted to open position. When positive, position is short
    }

    struct AccountInfo {
        int256 collateralBalance;       // Quantity of collateral deposited in Perp vault in 10**18 decimals
        int256 owedRealizedPnl;         // USDC quantity of profit and loss in 10**18 decimals not yet settled to vault
        int256 pendingFundingPayments;  // USDC quantity of pending funding payments in 10**18 decimals
    }

    /* ============ Events ============ */

    /**
     * @dev Emitted on lever
     * @param _setToken         Instance of SetToken
     * @param _baseToken        Virtual token minted by the Perp protocol
     * @param _deltaBase        Change in baseToken position size resulting from trade
     * @param _deltaQuote       Change in vUSDC position size resulting from trade
     * @param _protocolFee      Quantity in collateral decimals sent to fee recipient during lever trade
     */
    event LeverageIncreased(
        ISetToken indexed _setToken,
        address indexed _baseToken,
        uint256 _deltaBase,
        uint256 _deltaQuote,
        uint256 _protocolFee
    );

    /**
     * @dev Emitted on delever
     * @param _setToken         Instance of SetToken
     * @param _baseToken        Virtual token minted by the Perp protocol
     * @param _deltaBase        Change in baseToken position size resulting from trade
     * @param _deltaQuote       Change in vUSDC position size resulting from trade
     * @param _protocolFee      Quantity in collateral decimals sent to fee recipient during lever trade
     */
    event LeverageDecreased(
        ISetToken indexed _setToken,
        address indexed _baseToken,
        uint256 _deltaBase,
        uint256 _deltaQuote,
        uint256 _protocolFee
    );

    /**
     * @dev Emitted on updateAllowedSetToken()
     * @param _setToken SetToken being whose allowance to initialize this module is being updated
     * @param _added    true if added false if removed
     */
    event SetTokenStatusUpdated(
        ISetToken indexed _setToken,
        bool indexed _added
    );

    /**
     * @dev Emitted on updateAnySetAllowed()
     * @param _anySetAllowed    true if any set is allowed to initialize this module, false otherwise
     */
    event AnySetAllowedUpdated(
        bool indexed _anySetAllowed
    );

    /* ============ Constants ============ */

    // String identifying the DebtIssuanceModule in the IntegrationRegistry. Note: Governance must add DefaultIssuanceModule as
    // the string as the integration name
    string constant internal DEFAULT_ISSUANCE_MODULE_NAME = "DefaultIssuanceModule";

    // 0 index stores protocol fee % on the controller, charged in the _executeTrade function
    uint256 constant internal PROTOCOL_TRADE_FEE_INDEX = 0;

    /* ============ State Variables ============ */

    // PerpV2 contract which provides getters for base, quote, and owedRealizedPnl balances
    IAccountBalance public immutable perpAccountBalance;

    // PerpV2 contract which provides a trading API
    IClearingHouse public immutable perpClearingHouse;

    // PerpV2 contract which manages trading logic. Provides getters for UniswapV3 pools and pending funding balances
    IExchange public immutable perpExchange;

    // PerpV2 contract which handles deposits and withdrawals. Provides getter for collateral balances
    IVault public immutable perpVault;

    // TODO - REMOVE: PerpV2 contract which makes it possible to simulate a trade before it occurs
    IQuoter public immutable perpQuoter;

    // Mapping of SetTokens to an array of virtual token addresses the Set has open positions for.
    // Array is automatically updated when new positions are opened or old positions are zeroed out.
    mapping(ISetToken => address[]) public positions;

    // Mapping of SetTokens to the token used as a vault deposit. NOTE: only a single collateral type is allowed
    // per SetToken at any given time.
    mapping(ISetToken => IERC20) public collateralToken;

    // Mapping of SetToken to boolean indicating if SetToken is on allow list. Updateable by governance
    mapping(ISetToken => bool) public allowedSetTokens;

    // Boolean that returns if any SetToken can initialize this module. If false, then subject to allow list.
    // Updateable by governance.
    bool public anySetAllowed;

    /* ============ Constructor ============ */

    /**
     * @dev Sets external PerpV2 Protocol addresses.
     * @param _controller               Address of controller contract
     * @param _perpAccountBalance       Address of Perp AccountBalance contract
     * @param _perpClearingHouse        Address of Perp ClearingHouse contract
     * @param _perpExchange             Address of Perp Exchange contract
     * @param _perpVault                Address of Perp Vault contract
     * @param _perpQuoter               Address of Perp Quoter contract
     */
    constructor(
        IController _controller,
        IAccountBalance _perpAccountBalance,
        IClearingHouse _perpClearingHouse,
        IExchange _perpExchange,
        IVault _perpVault,
        IQuoter _perpQuoter // TODO: REMOVE
    )
        public
        ModuleBase(_controller)
    {
        perpAccountBalance = _perpAccountBalance;
        perpClearingHouse = _perpClearingHouse;
        perpExchange = _perpExchange;
        perpVault = _perpVault;
        perpQuoter = _perpQuoter;
    }

    /* ============ External Functions ============ */

    /**
     * @dev MANAGER ONLY: Raises leverage ratio for a virtual token by increasing the magnitude of its position,
     * Providing a positive value for `_baseQuantityUnits` buys vToken on UniswapV3 via Perp's ClearingHouse,
     * Providing a negative value (when increasing leverage for an inverse position) sells the token.
     * `_receiveQuoteQuantityUnits` defines a min-receive-like slippage bound for the amount of vUSDC quote
     * asset the trade will either pay or receive as a result of the action.
     *
     * | ----------------------------------------------------------------------------------------------- |
     * | Type  |  Action | Goal                      | `receiveQuoteQuantity`      | `baseQuantityUnits` |
     * | ----- |-------- | ------------------------- | --------------------------- | ------------------- |
     * | Long  | Buy     | pay least amt. of vQuote  | upper bound of input quote  | positive            |
     * | Short | Sell    | get most amt. of vQuote   | lower bound of output quote | negative            |
     * | ----------------------------------------------------------------------------------------------- |
     *
     * @param _setToken                     Instance of the SetToken
     * @param _baseToken                    Address virtual token being traded
     * @param _baseQuantityUnits            Quantity of virtual token to trade in position units
     * @param _receiveQuoteQuantityUnits    Max/min of vQuote asset to pay/receive when buying or selling
     */
    function lever(
        ISetToken _setToken,
        address _baseToken,
        int256 _baseQuantityUnits,
        uint256 _receiveQuoteQuantityUnits
    )
        external
        nonReentrant
        onlyManagerAndValidSet(_setToken)
    {
        ActionInfo memory actionInfo = _createAndValidateActionInfo(
            _setToken,
            _baseToken,
            _baseQuantityUnits,
            _receiveQuoteQuantityUnits
        );

        (uint256 deltaBase, uint256 deltaQuote) = _executeTrade(actionInfo);

        // TODO: Double-check deltas? Can we trust oppositeBoundAmount?

        uint256 protocolFee = _accrueProtocolFee(_setToken, deltaQuote);

        // TODO: Update externalPositionUnit for collateralToken ?

        _updatePositionList(_setToken, _baseToken);

        emit LeverageIncreased(
            _setToken,
            _baseToken,
            deltaBase,
            deltaQuote,
            protocolFee
        );
    }


    /**
     * @dev MANAGER ONLY: Lowers leverage ratio for a virtual token by decreasing the magnitude of its position,
     * Providing a positive value for `_baseQuantityUnits` sells vToken on UniswapV3 via Perp's ClearingHouse,
     * Providing a negative value (when decreasing leverage for an inverse position) buys the token, reducing
     * the size of its negative balance. `_receiveQuoteQuantityUnits` defines a min-receive-like slippage bound for
     * the amount of vUSDC quote asset the trade will either pay or receive as a result of the action.
     *
     * | ----------------------------------------------------------------------------------------------- |
     * | Type  |  Action | Goal                      | `receiveQuoteQuantity`      | `baseQuantityUnits` |
     * | ----- |-------- | ------------------------- | --------------------------- | ------------------- |
     * | Long  | Sell    | get most amt. of vQuote   | lower bound of output quote | positive            |
     * | Short | Buy     | pay least amt. of vQuote  | upper bound of input quote  | negative            |
     * | ----------------------------------------------------------------------------------------------- |
     *
     * @param _setToken                     Instance of the SetToken
     * @param _baseToken                    Address virtual token being traded
     * @param _baseQuantityUnits            Quantity of virtual token to trade in position units
     * @param _receiveQuoteQuantityUnits    Max/min of vQuote asset to pay/receive when buying or selling
     */

    function delever(
        ISetToken _setToken,
        address _baseToken,
        int256 _baseQuantityUnits,
        uint256 _receiveQuoteQuantityUnits
    )
        external
        nonReentrant
        onlyManagerAndValidSet(_setToken)
    {
        ActionInfo memory actionInfo = _createAndValidateActionInfo(
            _setToken,
            _baseToken,
            _baseQuantityUnits.mul(-1),
            _receiveQuoteQuantityUnits
        );

        (uint256 deltaBase, uint256 deltaQuote) = _executeTrade(actionInfo);

        // TODO: Double-check deltas? Can we trust oppositeBoundAmount?

        uint256 protocolFee = _accrueProtocolFee(_setToken, deltaQuote);

        // TODO: Update externalPositionUnit for collateralToken ?

        _updatePositionList(_setToken, _baseToken);

        emit LeverageDecreased(
            _setToken,
            _baseToken,
            deltaBase,
            deltaQuote,
            protocolFee
        );
    }

    /**
     * @dev MANAGER ONLY: Deposits default position collateral token into the PerpV2 Vault, increasing
     * the size of the Perp account external position. This method is useful for establishing initial
     * collateralization ratios, e.g the flow when setting up a 2X external position would be to deposit
     * 100 units of USDC and execute a lever trade for ~200 vUSDC worth of vToken with the difference
     * between these made up as automatically "issued" margin debt in the PerpV2 system.
     *
     * @param  _setToken                    Instance of the SetToken
     * @param  _collateralQuantityUnits     Quantity of collateral to deposit in position units
     */
    function deposit(
      ISetToken _setToken,
      uint256 _collateralQuantityUnits
    )
      public
      nonReentrant
      onlyManagerAndValidSet(_setToken)
    {
        _deposit(_setToken, _collateralQuantityUnits);
    }

    /**
     * @dev MANAGER ONLY: Withdraws collateral token from the PerpV2 Vault to a default position on
     * the SetToken. This method is useful when adjusting the overall composition of a Set which has
     * a Perp account external position as one of several components.
     *
     * NOTE: Within PerpV2, `withdraw` settles `owedRealizedPnl` and any pending funding payments
     * to the Perp vault prior to transfer.   // TODO: DOUBLE-CHECK THIS... and what are implications?
     *
     * @param  _setToken                    Instance of the SetToken
     * @param  _collateralQuantityUnits     Quantity of collateral to withdraw in position units
     */
    function withdraw(
      ISetToken _setToken,
      uint256 _collateralQuantityUnits
    )
      public
      nonReentrant
      onlyManagerAndValidSet(_setToken)
    {
        require(_collateralQuantityUnits > 0, "Withdraw amount is 0");
        _withdraw(_setToken, _collateralQuantityUnits, true);
    }

    /**
     * @dev MANAGER ONLY: Initializes this module to the SetToken. Sets the identity of collateral token used
     * for deposits into PerpV2. Either the SetToken needs to be on the allowed list or anySetAllowed
     * needs to be true. Only callable by the SetToken's manager.
     *
     * @param _setToken             Instance of the SetToken to initialize
     * @param _collateralToken      Address of ERC20 token to use for PerpV2 collateral deposits
     */
    function initialize(
        ISetToken _setToken,
        IERC20 _collateralToken
    )
        external
        onlySetManager(_setToken, msg.sender)
        onlyValidAndPendingSet(_setToken)
    {
        if (!anySetAllowed) {
            require(allowedSetTokens[_setToken], "Not allowed SetToken");
        }

        // Initialize module before trying register
        _setToken.initializeModule();

        // Get debt issuance module registered to this module and require that it is initialized
        require(_setToken.isInitializedModule(
            getAndValidateAdapter(DEFAULT_ISSUANCE_MODULE_NAME)),
            "Issuance not initialized"
        );

        // Try if register exists on any of the modules including the debt issuance module
        address[] memory modules = _setToken.getModules();
        for(uint256 i = 0; i < modules.length; i++) {
            try IDebtIssuanceModule(modules[i]).registerToIssuanceModule(_setToken) {} catch {}
        }

        // Set collateralToken
        _setCollateralToken(_setToken, _collateralToken);
    }

    /**
     * @dev MANAGER ONLY: Removes this module from the SetToken, via call by the SetToken. Deletes
     * collateralToken and position mappings associated with SetToken.
     *
     * NOTE: Function will revert if there are any remaining collateral deposits in the PerpV2 vault.
     */
    function removeModule() external override onlyValidAndInitializedSet(ISetToken(msg.sender)) {
        ISetToken setToken = ISetToken(msg.sender);
        require(_getCollateralBalance(setToken) == 0, "Collateral balance remaining");

        delete positions[setToken]; // Should already be empty
        delete collateralToken[setToken];

        // Try if unregister exists on any of the modules
        address[] memory modules = setToken.getModules();
        for(uint256 i = 0; i < modules.length; i++) {
            try IDebtIssuanceModule(modules[i]).unregisterFromIssuanceModule(setToken) {} catch {}
        }
    }

    /**
     * @dev MANAGER ONLY: Add registration of this module on the debt issuance module for the SetToken.
     * Note: if the debt issuance module is not added to SetToken before this module is initialized, then
     * this function needs to be called if the debt issuance module is later added and initialized to prevent state
     * inconsistencies
     *
     * @param _setToken             Instance of the SetToken
     * @param _debtIssuanceModule   Debt issuance module address to register
     */
    function registerToModule(ISetToken _setToken, IDebtIssuanceModule _debtIssuanceModule) external onlyManagerAndValidSet(_setToken) {
        require(_setToken.isInitializedModule(address(_debtIssuanceModule)), "Issuance not initialized");

        _debtIssuanceModule.registerToIssuanceModule(_setToken);
    }

    /**
     * @dev GOVERNANCE ONLY: Enable/disable ability of a SetToken to initialize this module.
     *
     * @param _setToken             Instance of the SetToken
     * @param _status               Bool indicating if _setToken is allowed to initialize this module
     */
    function updateAllowedSetToken(ISetToken _setToken, bool _status) external onlyOwner {
        require(controller.isSet(address(_setToken)) || allowedSetTokens[_setToken], "Invalid SetToken");
        allowedSetTokens[_setToken] = _status;
        emit SetTokenStatusUpdated(_setToken, _status);
    }

    /**
     * @dev GOVERNANCE ONLY: Toggle whether ANY SetToken is allowed to initialize this module.
     *
     * @param _anySetAllowed             Bool indicating if ANY SetToken is allowed to initialize this module
     */
    function updateAnySetAllowed(bool _anySetAllowed) external onlyOwner {
        anySetAllowed = _anySetAllowed;
        emit AnySetAllowedUpdated(_anySetAllowed);
    }

    /**
     * @dev MANAGER ONLY: Sets the identity of the token used for deposits into the PerpV2 protocol.
     * Because PerpV2 uses vUSDC as a universal quote asset (and only accepts USDC collateral in
     * its initial version) simple Perp account positions will use USDC. However, there are applications
     * like basis trading where depositing alternative tokens and shorting them in PerpV2 markets lets
     * you create a delta neutral position. Because `collateralToken` is also configured during initialization
     * this method would only be used if manager was switching from one Perp account strategy to another
     * (or correcting an initialization error).
     *
     * NOTE: reverts if SetToken has an existing collateral balance in the Perp vault
     *
     * @param _setToken                 Instance of the SetToken
     * @param _collateralToken          ERC20 token to use for PerpV2 collateral deposits
     */
    function setCollateralToken(
      ISetToken _setToken,
      IERC20 _collateralToken
    )
      external
      onlyManagerAndValidSet(ISetToken(_setToken))
    {
        _setCollateralToken(_setToken, _collateralToken);
    }

    // TODO: WIP.... `moduleIssueHook` will trade on margin and set the external position unit to
    // recoup its spend in the componentIssueHook. (Will also have slippage bounds?)
    /**
     * @dev MODULE ONLY: Hook called prior to issuance. Only callable by valid module.
     * @param _setToken             Instance of the SetToken
     * @param _setTokenQuantity     Quantity of Set to issue
     */
    function moduleIssueHook(
        ISetToken _setToken,
        uint256 _setTokenQuantity
    )
        external
        override
        onlyModule(_setToken)
    {
        int256 usdcAmountIn = 0;

        PositionInfo[] memory positionInfo = getPositionInfo(_setToken);

        for(uint i = 0; i < positionInfo.length; i++) {
            int256 basePositionUnit = positionInfo[i].baseBalance.preciseDiv(_setToken.totalSupply().toInt256());
            int256 baseTradeNotionalQuantity = _abs(basePositionUnit.preciseMul(_setTokenQuantity.toInt256()));

            // Simulate trade to get its real cost
            ActionInfo memory actionInfo = _createAndValidateActionInfo(
                _setToken,
                positionInfo[i].baseToken,
                baseTradeNotionalQuantity,
                0
            );

            // TODO: ACTUALLY TRADE HERE....
            IQuoter.SwapResponse memory swapResponse = _simulateTrade(actionInfo);

            usdcAmountIn += _calculateUSDCAmountIn(
                _setToken,
                _setTokenQuantity,
                baseTradeNotionalQuantity,
                basePositionUnit,
                positionInfo[i],
                swapResponse.deltaAvailableQuote
            );
        }

        // Set USDC externalPositionUnit such that DIM can use it for transfer calculation
        int256 newExternalPositionUnit = usdcAmountIn.preciseDiv(_setTokenQuantity.toInt256());

        _setToken.editExternalPositionUnit(
            address(collateralToken[_setToken]),
            address(this),
            newExternalPositionUnit
        );
    }

    /**
     * @dev MODULE ONLY: Hook called prior to redemption in the issuance module. Trades out of existing
     * positions to make redemption capital withdrawable from PerpV2 vault. Sets the `externalPositionUnit`
     * equal to the realizable value of account in position units (as measured by the trade outcomes for
     * this redemption). Any `owedRealizedPnl` and pending funding payments are socialized in this step so
     * that redeemer pays/receives their share of them.
     *
     * @param _setToken             Instance of the SetToken
     * @param _setTokenQuantity     Quantity of SetToken to redeem
     */
    function moduleRedeemHook(
        ISetToken _setToken,
        uint256 _setTokenQuantity
    )
        external
        override
        onlyModule(_setToken)
    {
        int256 realizedPnL = 0;
        int256 setTokenQuantity = _setTokenQuantity.toInt256();

        PositionInfo[] memory positionInfo = getPositionInfo(_setToken);
        AccountInfo memory accountInfo = getAccountInfo(_setToken);

        // Calculate already accrued PnL from non-issuance/redemption sources (ex: levering)
        int256 totalFundingAndCarriedPnL = accountInfo.pendingFundingPayments + accountInfo.owedRealizedPnl;
        int256 owedRealizedPnlPositionUnit = totalFundingAndCarriedPnL.preciseDiv(_setToken.totalSupply().toInt256());

        for (uint256 i = 0; i < positionInfo.length; i++) {
            // Calculate amount to trade
            int256 basePositionUnit = positionInfo[i].baseBalance.preciseDiv(_setToken.totalSupply().toInt256());
            int256 baseTradeNotionalQuantity = _abs(setTokenQuantity.preciseMul(basePositionUnit));

            // Calculate amount quote debt will be reduced by
            int256 closeRatio = baseTradeNotionalQuantity.preciseDiv(positionInfo[i].baseBalance);
            int256 reducedOpenNotional = positionInfo[i].quoteBalance.preciseMul(closeRatio);

            // Trade
            ActionInfo memory actionInfo = _createAndValidateActionInfo(
                _setToken,
                positionInfo[i].baseToken,
                baseTradeNotionalQuantity.mul(-1),
                0
            );

            (,uint256 deltaQuote) = _executeTrade(actionInfo);

            // Calculate realized PnL for and add to running total.
            // When basePositionUnit is positive, position is long.
            if (basePositionUnit >= 0){
                realizedPnL += reducedOpenNotional + deltaQuote.toInt256();
            } else {
                realizedPnL += reducedOpenNotional - deltaQuote.toInt256();
            }
        }

        // Calculate amount of USDC to withdraw
        int256 collateralPositionUnit = _getCollateralBalance(_setToken).preciseDiv(_setToken.totalSupply().toInt256());

        int256 usdcToWithdraw =
            collateralPositionUnit.preciseMul(setTokenQuantity) +
            owedRealizedPnlPositionUnit.preciseMul(setTokenQuantity) +
            realizedPnL;

        // Set the external position unit for DIM
        _setToken.editExternalPosition(
            address(collateralToken[_setToken]),
            address(this),
            usdcToWithdraw.preciseDiv(setTokenQuantity),
            ""
        );
    }

    // TODO: WIP.... This hook will likely not trade and just re-collateralize the Perp vault...
    /**
     * @dev MODULE ONLY: Hook called prior to looping through each component on issuance. Deposits
     * collateral into Perp protocol from SetToken default position.
     * @param _setToken             Instance of the SetToken
     * @param _setTokenQuantity     Quantity of SetToken to issue
     * @param _component            Address of deposit collateral component
     */
    function componentIssueHook(
        ISetToken _setToken,
        uint256 _setTokenQuantity,
        IERC20 _component,
        bool /* isEquity */
    )
        external
        override
        onlyModule(_setToken)
    {
        // Deposit collateral from SetToken into PerpV2
        int256 externalPositionUnit = _setToken.getExternalPositionRealUnit(address(_component), address(this));
        uint256 usdcTransferInQuantityUnits = _setTokenQuantity.preciseMul(externalPositionUnit.toUint256());
        _deposit(_setToken, usdcTransferInQuantityUnits);

        PositionInfo[] memory positionInfo = getPositionInfo(_setToken);

        for(uint i = 0; i < positionInfo.length; i++) {
            int256 basePositionUnit = positionInfo[i].baseBalance.preciseDiv(_setToken.totalSupply().toInt256());
            int256 baseTradeNotionalQuantity = _abs(_setTokenQuantity.toInt256().preciseMul(basePositionUnit));

            ActionInfo memory actionInfo = _createAndValidateActionInfo(
                _setToken,
                positionInfo[i].baseToken,
                baseTradeNotionalQuantity,
                0
            );

            _executeTrade(actionInfo);
        }
    }

    /**
     * @dev MODULE ONLY: Hook called prior to looping through each component on redemption. Withdraws
     * collateral from Perp protocol to SetToken default position *without* updating the default position unit.
     * Called by issuance module's `resolveEquityPositions` method which immediately transfers the collateral
     * component from SetToken to redeemer after this hook executes.
     *
     * @param _setToken             Instance of the SetToken
     * @param _setTokenQuantity     Quantity of SetToken to redeem
     * @param _component            Address of deposit collateral component
     */
    function componentRedeemHook(
        ISetToken _setToken,
        uint256 _setTokenQuantity,
        IERC20 _component,
        bool /* isEquity */
    ) external override onlyModule(_setToken) {
        int256 externalPositionUnit = _setToken.getExternalPositionRealUnit(address(_component), address(this));
        uint256 usdcTransferOutQuantityUnits = _setTokenQuantity.preciseMul(externalPositionUnit.toUint256());

        // console.log(usdcTransferOutQuantityUnits, 'usdcTransferOutQuantityUnits');
        // console.log(perpVault.balanceOf(address(_setToken)).toUint256(), 'balanceOf(_setToken)');

        _withdraw(_setToken, usdcTransferOutQuantityUnits, false);
    }

    /* ============ External Getter Functions ============ */

    /**
     * @dev Gets Perp positions open for SetToken. Returns a PositionInfo array representing all positions
     * open for the SetToken
     *
     * @param _setToken         Instance of SetToken
     *
     * @return PositionInfo array, in which each element has properties for:
     *
     *         + baseToken address,
     *         + baseToken position size (10**18)
     *         + USDC quote asset position size (10**18).
     */
    function getPositionInfo(ISetToken _setToken) public view returns (PositionInfo[] memory) {
        PositionInfo[] memory positionInfo = new PositionInfo[](positions[_setToken].length);

        for(uint i = 0; i < positions[_setToken].length; i++){
            positionInfo[i] = PositionInfo({
                baseToken: positions[_setToken][i],
                baseBalance: perpAccountBalance.getBase(
                    address(_setToken),
                    positions[_setToken][i]
                ),
                quoteBalance: perpAccountBalance.getQuote(
                    address(_setToken),
                    positions[_setToken][i]
                )
            });
        }

        return positionInfo;
    }

    /**
     * @dev Gets Perp account info for SetToken. Returns an AccountInfo struct containing account wide
     * (rather than position specific) balance info
     *
     * @param  _setToken            Instance of the SetToken
     *
     * @return accountInfo          struct with properties for:
     *
     *         + collateral balance (10**18, regardless of underlying collateral decimals)
     *         + owed realized Pnl` (10**18)
     *         + pending funding payments (10**18)
     */
    function getAccountInfo(ISetToken _setToken) public view returns (AccountInfo memory accountInfo) {
        accountInfo = AccountInfo({
            collateralBalance: _getCollateralBalance(_setToken),
            owedRealizedPnl: perpAccountBalance.getOwedRealizedPnl(address(_setToken)),
            pendingFundingPayments: perpExchange.getAllPendingFundingPayment(address(_setToken))
        });
    }

    /**
     * @dev Gets the mid-point price of a virtual asset from UniswapV3 markets maintained by Perp Protocol
     *
     * @param  _baseToken)          Address of virtual token to price
     * @return price                Mid-point price of virtual token in UniswapV3 AMM market
     */
    function getSpotPrice(address _baseToken) public view returns (uint256 price) {
        address pool = perpExchange.getPool(_baseToken);
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
        uint256 priceX96 = _formatSqrtPriceX96ToPriceX96(sqrtPriceX96);
        return _formatX96ToX10_18(priceX96);
    }

    /* ============ Internal Functions ============ */

    /**
     * @dev Invoke deposit from SetToken using PerpV2 library. Creates a collateral deposit in Perp vault
     */
    function _deposit(ISetToken _setToken, uint256 _collateralQuantityUnits) internal {
        uint256 initialCollateralPositionBalance = collateralToken[_setToken].balanceOf(address(_setToken));
        uint256 notionalCollateralQuantity = _formatCollateralQuantityUnits(_setToken, _collateralQuantityUnits);

        _setToken.invokeApprove(
            address(collateralToken[_setToken]),
            address(perpVault),
            notionalCollateralQuantity
        );

        _setToken.invokeDeposit(perpVault, collateralToken[_setToken], notionalCollateralQuantity);

        _setToken.calculateAndEditDefaultPosition(
            address(collateralToken[_setToken]),
            _setToken.totalSupply(),
            initialCollateralPositionBalance
        );

        // TODO: Update externalPositionUnit for collateralToken ?
    }

    /**
     * @dev Invoke withdraw from SetToken using PerpV2 library. Withdraws collateral token from Perp vault
     * into a default position. Optionally updates the collateral asset's default position unit.
     */
    function _withdraw(ISetToken _setToken, uint256 _collateralQuantityUnits, bool editDefaultPosition) internal {
        if (_collateralQuantityUnits == 0) return;

        uint256 initialCollateralPositionBalance = collateralToken[_setToken].balanceOf(address(_setToken));
        uint256 notionalCollateralQuantity = _formatCollateralQuantityUnits(_setToken, _collateralQuantityUnits);

        //console.log(notionalCollateralQuantity, 'notionalCollateralQuantity');
        //console.log(perpVault.getFreeCollateral(address(_setToken)), 'freeCollateral');

        _setToken.invokeWithdraw(perpVault, collateralToken[_setToken], notionalCollateralQuantity);

        // Skip position editing in cases (like fee payment) where we withdraw and immediately
        // forward the amount to another recipient.
        if (editDefaultPosition) {
            _setToken.calculateAndEditDefaultPosition(
                address(collateralToken[_setToken]),
                _setToken.totalSupply(),
                initialCollateralPositionBalance
            );
        }

        // TODO: Update externalPositionUnit for collateralToken ?
    }

    /**
     * @dev Formats Perp Protocol openPosition call and executes via SetToken (and PerpV2 lib)
     * @return uint256     The base position delta resulting from the trade
     * @return uint256     The quote asset position delta resulting from the trade
     */
    function _executeTrade(ActionInfo memory _actionInfo) internal returns (uint256, uint256) {
        IClearingHouse.OpenPositionParams memory params = IClearingHouse.OpenPositionParams({
            baseToken: _actionInfo.baseToken,
            isBaseToQuote: _actionInfo.isBaseToQuote,
            isExactInput: _actionInfo.isExactInput,
            amount: _actionInfo.amount.toUint256(),
            oppositeAmountBound: _actionInfo.oppositeAmountBound,
            deadline: PreciseUnitMath.maxUint256(),
            sqrtPriceLimitX96: 0,
            referralCode: bytes32(0)
        });

        return _actionInfo.setToken.invokeOpenPosition(perpClearingHouse, params);
    }

    // TODO: REMOVE...
    function _simulateTrade(ActionInfo memory _actionInfo) internal returns (IQuoter.SwapResponse memory) {
        IQuoter.SwapParams memory params = IQuoter.SwapParams({
            baseToken: _actionInfo.baseToken,
            isBaseToQuote: _actionInfo.isBaseToQuote,
            isExactInput: _actionInfo.isExactInput,
            amount: _actionInfo.amount.toUint256(),
            sqrtPriceLimitX96: 0
        });

        return _actionInfo.setToken.invokeSwap(perpQuoter, params);
    }

    /**
     * @dev Calculates protocol fee on module and pays protocol fee from SetToken
     * @return uint256          Total protocol fee paid in underlying collateral decimals e.g (USDC = 6)
     */
    function _accrueProtocolFee(
        ISetToken _setToken,
        uint256 _exchangedQuantity
    )
        internal
        returns(uint256)
    {
        IERC20 token = collateralToken[_setToken];

        uint256 protocolFee = getModuleFee(PROTOCOL_TRADE_FEE_INDEX, _exchangedQuantity);
        uint256 protocolFeeUnits = protocolFee.preciseDiv(_setToken.totalSupply());

        _withdraw(_setToken, protocolFeeUnits, false);

        uint256 protocolFeeInCollateralDecimals = _formatCollateralToken(
            protocolFee,
            ERC20(address(token)).decimals()
        );

        payProtocolFeeFromSetToken(_setToken, address(token), protocolFeeInCollateralDecimals);

        return protocolFeeInCollateralDecimals;
    }

    /**
     * @dev Construct the ActionInfo struct for lever and delever
     * @return ActionInfo       Instance of constructed ActionInfo struct
     */
    function _createAndValidateActionInfo(
        ISetToken _setToken,
        address _baseToken,
        int256 _baseTokenQuantityUnits,
        uint256 _recieveQuoteQuantityUnits
    )
        internal
        view
        returns(ActionInfo memory)
    {
        uint256 totalSupply = _setToken.totalSupply();

        return _createAndValidateActionInfoNotional(
            _setToken,
            _baseToken,
            _baseTokenQuantityUnits.preciseMul(totalSupply.toInt256()),
            _recieveQuoteQuantityUnits.preciseMul(totalSupply)
        );
    }

    /**
     * @dev Construct the ActionInfo struct for lever and delever accepting notional units.
     *
     * | --------------------------------------------------------------------------------------------------|
     * | Action |  Type | isB2Q | Exact In / Out | Amount    | Recieve Token | Receive Description         |
     * | -------|-------|-------|----------------|-----------| ------------- | ----------------------------|
     * | Buy    | Long  | false | exact output   | baseToken | quoteToken    | upper bound of input quote  |
     * | Buy    | Short | true  | exact input    | baseToken | quoteToken    | lower bound of output quote |
     * | Sell   | Long  | true  | exact input    | baseToken | quoteToken    | lower bound of output quote |
     * | Sell   | Short | false | exact output   | baseToken | quoteToken    | upper bound of input quote  |
     * |---------------------------------------------------------------------------------------------------|
     *
     * @return ActionInfo       Instance of constructed ActionInfo struct
     */
    function _createAndValidateActionInfoNotional(
        ISetToken _setToken,
        address _baseToken,
        int256 _notionalBaseTokenQuantity,
        uint256 _notionalQuoteReceiveQuantity
    )
        internal
        pure
        returns(ActionInfo memory)
    {
        bool isShort = _notionalBaseTokenQuantity < 0;

        ActionInfo memory actionInfo = ActionInfo ({
            setToken: _setToken,
            baseToken: _baseToken,
            isBaseToQuote: isShort,
            isExactInput: isShort,
            amount: _abs(_notionalBaseTokenQuantity),
            oppositeAmountBound: _notionalQuoteReceiveQuantity
        });

        _validateCommon(actionInfo);

        return actionInfo;
    }

    /**
     * @dev Update position address array if a token has been newly added or completely sold off
     * during lever/delever
     */
    function _updatePositionList(ISetToken _setToken, address _baseToken) internal {
        int256 baseBalance = perpAccountBalance.getBase(address(_setToken), _baseToken);

        // TODO: Add storage variants of contains, indexOf to AddressArrayUtils ?
        address[] memory positionList = positions[_setToken];
        bool baseTokenExists = positionList.contains(_baseToken);

        if (baseTokenExists && baseBalance == 0) {
            positions[_setToken].removeStorage(_baseToken);
        }  else if (!baseTokenExists) {
            positions[_setToken].push(_baseToken);
        }
    }

    /**
     * @dev Calculate amount of USDC to transfer in to pay for issuance. Slippage is paid for
     * by issuer and any pending funding payments / carried owedRealizedPnl are paid for by
     * existing Set holders. Returned value is used to set the Perp account's external position unit.
     *
     * @return int256 Amount of USDC to transfer in.
     */
    function _calculateUSDCAmountIn(
        ISetToken _setToken,
        uint256 _setTokenQuantity,
        int256 _baseTradeQuantity,
        int256 _basePositionUnit,
        PositionInfo memory _positionInfo,
        uint256 _deltaQuote
    )
        internal
        view
        returns(int256)
    {
        // Calculate ideal quote cost e.g without slippage and Perp protocol fees
        int256 spotPrice = getSpotPrice(_positionInfo.baseToken).toInt256();
        int256 idealDeltaQuote = _baseTradeQuantity.preciseMul(spotPrice);

        // Calculate slippage for long and short cases
        int256 slippageQuantity = (_basePositionUnit >= 0)
            ? _deltaQuote.toInt256() - idealDeltaQuote
            : idealDeltaQuote - _deltaQuote.toInt256();

        // Calculate current leverage
        int256 currentLeverage = _calculateCurrentLeverage(
            _positionInfo.baseBalance,
            _positionInfo.quoteBalance,
            _getCollateralBalance(_setToken),
            spotPrice
        );

        int256 owedRealizedPnlDiscountQuantity = _calculateOwedRealizedPnlDiscount(
            _setToken,
            _setTokenQuantity
        );

        return (
            slippageQuantity +
            owedRealizedPnlDiscountQuantity +
            idealDeltaQuote.preciseDiv(currentLeverage)
        );
    }

    /**
     * @dev Calculate the total amount to discount an issuance purchase by given pending funding payments
     * and unsettled owedRealizedPnl balances. These amounts are socialized among existing shareholders.
     *
     * @return int256 Total quantity to discount
     */
    function _calculateOwedRealizedPnlDiscount(
        ISetToken _setToken,
        uint256 _setTokenQuantity
    )
        internal
        view
        returns (int256)
    {
        // Calculate addtional usdcAmountIn and add to running total.
        int256 owedRealizedPnl = perpAccountBalance.getOwedRealizedPnl(address(_setToken));
        int256 pendingFundingPayments = perpExchange.getAllPendingFundingPayment(address(_setToken));

        return (owedRealizedPnl + pendingFundingPayments)
            .preciseDiv(_setToken.totalSupply().toInt256())
            .preciseMul(_setTokenQuantity.toInt256());
    }

    /**
     * @dev Calculate current leverage ratio. This value is used to scale the amount of USDC to transfer
     * in during issuance so new set holder funds are proportionate to the leverage ratio pre-established
     * for the set.
     *
     * @return int256 Leverage ratio
     */
    function _calculateCurrentLeverage(
        int256 baseBalance,
        int256 quoteBalance,
        int256 collateralBalance,
        int256 spotPrice
    )
        internal
        pure
        returns (int256)
    {
        int256 basePositionValue = baseBalance.preciseMul(spotPrice);

        return basePositionValue.preciseDiv(
            basePositionValue +
            quoteBalance +
            collateralBalance
        );
    }

    /**
     * @dev Sets the identity of the Perp accounts deposit collateral token. Reverts if there is
     * an existing collateral balance. Only one collateral type is allowed.
     */
    function _setCollateralToken(
      ISetToken _setToken,
      IERC20 _collateralToken
    )
      internal
    {
        require(perpVault.balanceOf(address(_setToken)) == 0, "Existing collateral balance");
        collateralToken[_setToken] = _collateralToken;
    }

    /**
     * @dev Validate common requirements for lever and delever
     */
    function _validateCommon(ActionInfo memory _actionInfo) internal pure {
        // TODO: other validations....
        require(_actionInfo.amount > 0, "Amount is 0");
    }

    /**
     * @dev Validates if a new asset can be added as collateral asset for given SetToken
     */
    function _validateNewCollateralAsset(ISetToken _setToken, IERC20 _asset) internal view {
        // TODO:
        // require collateral is a default component on SetToken
        // require collateral is valid for deposit in PerpV2
    }


    // TODO: Add logic here to convert non-USDC collateral into USDC
    function _getCollateralBalance(ISetToken _setToken) internal view returns (int256) {
        int256 balance = perpVault.balanceOf(address(_setToken));
        uint8 decimals = ERC20(address(collateralToken[_setToken])).decimals();
        return _parseCollateralToken(balance, decimals);
    }

    function _formatCollateralQuantityUnits(
        ISetToken _setToken,
        uint256 _collateralQuantityUnits
    )
        internal
        view
        returns (uint256)
    {
        uint256 notionalQuantity = _collateralQuantityUnits.preciseMul(_setToken.totalSupply());

        uint8 decimals = ERC20(address(collateralToken[_setToken])).decimals();

        return _formatCollateralToken(
            notionalQuantity,
            decimals
        );
    }

    function _formatSqrtPriceX96ToPriceX96(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
    }

    function _formatX96ToX10_18(uint256 valueX96) internal pure returns (uint256) {
        return FullMath.mulDiv(valueX96, 1 ether, FixedPoint96.Q96);
    }

    function _formatCollateralToken(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        return amount.div(10**(18 - uint(decimals)));
    }

    function _parseCollateralToken(int256 amount, uint8 decimals) internal pure returns (int256) {
        return amount.mul(int256(10**(18 - uint(decimals))));
    }

    function _abs(int x) internal pure returns (int) {
        return x >= 0 ? x : -x;
    }
}