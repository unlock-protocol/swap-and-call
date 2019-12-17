pragma solidity ^0.5.0;

import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import 'hardlydifficult-ethereum-contracts/contracts/proxies/CallContract.sol';
import 'hardlydifficult-ethereum-contracts/contracts/utils/Gas.sol';
import 'hardlydifficult-ethereum-contracts/contracts/interfaces/IUniswapExchange.sol';
import 'hardlydifficult-ethereum-contracts/contracts/interfaces/IUniswapFactory.sol';


/**
 * @title Uniswap and call contract.
 * @notice Swaps ETH or tokens with Uniswap, calls another contract with approval to spend
 * the tokens, and refunds anything remaining.
 */
contract UniswapAndCall is
  // Reentrancy could be used to attempt to take a user's expected refund as well.
  ReentrancyGuard
{
  // For `isContract`
  using Address for address;
  // For `sendValue`
  using Address for address payable;
  // For `_call` and `_readUint`
  using CallContract for address;
  // For `safe`Approve/Transfer/TransferFrom
  using SafeERC20 for IERC20;

  /**
   * @notice The Uniswap factory for this network.
   * @dev Used to lookup the exchange address for a given token.
   */
  IUniswapFactory public uniswapFactory;

  // All the swap calls below will trigger this event when successful
  event SwapAndCall(
    address indexed _sender,
    address _fromToken,
    address _toToken,
    address indexed _contract,
    uint _amountIn,
    uint _amountRefunded
  );

  /**
   * @notice Initialize the contract with the uniswapFactory for this network.
   * @dev This address is not hardcoded to enable testing.
   */
  constructor(
    IUniswapFactory _uniswapFactory
  ) public {
    require(address(_uniswapFactory).isContract(), 'UNISWAP_ADDRESS_REQUIRED');
    uniswapFactory = _uniswapFactory;
  }

  /**
   * @notice Payable fallback function in order to accept ETH transfers.
   * @dev Used by the Uniswap exchange to refund any ETH remaining after a trade.
   */
  function() external payable {}

  /**
   * @notice Make any arbitrary call.  Generally not used.
   * @dev This contract is intended to be stateless. If someone were to deposit
   * tokens into this contract this function could be used to withdraw them.
   */
  function proxyCall(
    address _contract,
    bytes memory _callData,
    uint msgValue
  ) public
  {
    _contract._call(_callData, msgValue);
  }

  /**
   * @notice Approve and call contract, then require the amount charged matches the expected value.
   * @dev Used for ERC-20 token calls, ETH has a slightly different flow.
   */
  function _callContract(
    IERC20 _targetToken,
    uint _targetAmount,
    address _contract,
    bytes memory _callData
  ) private
  {
    // Approve the 3rd party contract to take tokens from this contract
    _targetToken.safeApprove(_contract, _targetAmount);

    // Call the 3rd party contract
    _contract._call(_callData, 0);

    // The 3rd party contract must consume all the tokens we approved for spending
    // We use this instead of balance in case some tokens have been transferred to the contract
    require(_targetToken.allowance(address(this), _contract) == 0, 'INCORRECT_TARGET_AMOUNT');
  }

  /**
   * @notice Swap ETH for the token a contract expects, make the call, and then refund
   * any ETH remaining.
   * @param _targetToken The ERC-20 token address to get from swapping out the ETH provided.
   * @param _targetAmount The exact amount which will be consumed by the _contract.
   */
  function uniswapEthAndCall(
    IERC20 _targetToken,
    uint _targetAmount,
    address _contract,
    bytes memory _callData
  ) public payable
    nonReentrant()
  {
    // Lookup the exchange address for the target token type
    IUniswapExchange exchange = IUniswapExchange(
      uniswapFactory.getExchange(address(_targetToken))
    );

    // Swap the ETH provided for exactly _targetAmount of tokens
    // balance is used here instead of msg.value in case the contract has a little dust left behind
    // Ignore the Uniswap deadline
    // Uniswap will send any remaining ETH back to this contract
    exchange.ethToTokenSwapOutput.value(address(this).balance)(_targetAmount, uint(-1));

    _callContract(_targetToken, _targetAmount, _contract, _callData);

    // Any ETH in the contract at this point can be refunded
    uint refund = address(this).balance;
    if(refund > Gas.gasPrice() * 2300)
    {
      msg.sender.sendValue(refund);
    }
    else
    {
      // It's not worth the gas cost to refund so leave the ETH here as a donation to the next user
      refund = 0;
    }

    emit SwapAndCall({
      _sender: msg.sender,
      _fromToken: address(0),
      _toToken: address(_targetToken),
      _contract: _contract,
      _amountIn: msg.value,
      _amountRefunded: refund
    });
  }

  /**
   * @notice `uniswapEthAndCall` for when the exact price is not known until the block is mined.
   * @param _priceCallData must return the exact cost as a uint.
   */
  function uniswapEthAndCallDynamicPrice(
    IERC20 _targetToken,
    address _contract,
    bytes memory _priceCallData,
    bytes memory _callData
  ) public payable
  {
    uint price = _contract._readUint(_priceCallData);
    uniswapEthAndCall(_targetToken, price, _contract, _callData);
  }

  /**
   * @notice Swap a token for the token a contract expects, make the call, and then refund
   * any of the orginal tokens remaining.
   * @param _sourceToken The ERC-20 token address the msg.sender is funding for this call.
   * @param _amountIn The max number of _sourceTokens the msg.sender is willing to spend.
   * @param _targetToken The ERC-20 token address to get from swapping out the tokens provided.
   * @param _targetAmount The exact amount which will be consumed by the _contract.
   */
  function uniswapTokenAndCall(
    IERC20 _sourceToken,
    uint _amountIn,
    IERC20 _targetToken,
    uint _targetAmount,
    address _contract,
    bytes memory _callData
  ) public
    nonReentrant()
  {
    // Lookup the exchange address for the source token type
    IUniswapExchange exchange = IUniswapExchange(
      uniswapFactory.getExchange(address(_sourceToken))
    );

    // Collect the tokens provided for the swap
    _sourceToken.safeTransferFrom(msg.sender, address(this), _amountIn);

    // Make the provided tokens available to the Uniswap contract
    _sourceToken.safeApprove(address(exchange), uint(-1));

    // Swap the tokens provided for exactly _targetAmount of _targetTokens
    // Ignore the Uniswap deadline and limits
    exchange.tokenToTokenSwapOutput(_targetAmount, uint(-1), uint(-1), uint(-1), address(_targetToken));

    _callContract(_targetToken, _targetAmount, _contract, _callData);

    // Any tokens in the contract at this point can be refunded
    uint refund = _sourceToken.balanceOf(address(this));
    if(refund > 0)
    {
      _sourceToken.safeTransfer(msg.sender, refund);
    }

    emit SwapAndCall({
      _sender: msg.sender,
      _fromToken: address(_sourceToken),
      _toToken: address(_targetToken),
      _contract: _contract,
      _amountIn: _amountIn,
      _amountRefunded: refund
    });
  }

  /**
   * @notice `uniswapTokenAndCall` for when the exact price is not known until the block is mined.
   * @param _priceCallData must return the exact cost as a uint.
   */
  function uniswapTokenAndCallDynamicPrice(
    IERC20 _sourceToken,
    uint _amountIn,
    IERC20 _targetToken,
    address _contract,
    bytes memory _priceCallData,
    bytes memory _callData
  ) public
  {
    uint price = _contract._readUint(_priceCallData);
    uniswapTokenAndCall(_sourceToken, _amountIn, _targetToken, price, _contract, _callData);
  }

  /**
   * @notice Swap a token for the ETH a contract expects, make the call, and then refund
   * any tokens remaining.
   * @param _amountIn The max number of _sourceTokens the msg.sender is willing to spend.
   * @param _sourceToken The ERC-20 token address the msg.sender is funding for this call.
   * @param _targetAmount The exact amount which will be consumed by the _contract.
   */
  function uniswapTokenToEthAndCall(
    IERC20 _sourceToken,
    uint _amountIn,
    uint _targetAmount,
    address _contract,
    bytes memory _callData
  ) public
    nonReentrant()
  {
    if(address(this).balance != 0)
    {
      // If funds are in the contract it would break our check below
      // so just give it to the msg.sender before we start
      msg.sender.sendValue(address(this).balance);
    }

    // Lookup the exchange address for the source token type
    IUniswapExchange exchange = IUniswapExchange(
      uniswapFactory.getExchange(address(_sourceToken))
    );

    // Collect the tokens provided for the swap
    _sourceToken.safeTransferFrom(msg.sender, address(this), _amountIn);

    // Make the provided tokens available to the Uniswap contract
    _sourceToken.safeApprove(address(exchange), uint(-1));

    // Swap the tokens provided for exactly _targetAmount of ETH
    // Ignore the Uniswap deadline and limits
    exchange.tokenToEthSwapOutput(_targetAmount, uint(-1), uint(-1));

    // Call the 3rd party contract
    _contract._call(_callData, _targetAmount);

    // The 3rd party contract must consume all the ETH we swapped for
    require(address(this).balance == 0, 'INCORRECT_TARGET_AMOUNT');

    // Any tokens in the contract at this point can be refunded
    uint refund = _sourceToken.balanceOf(address(this));
    if(refund > 0)
    {
      _sourceToken.safeTransfer(msg.sender, refund);
    }

    emit SwapAndCall({
      _sender: msg.sender,
      _fromToken: address(_sourceToken),
      _toToken: address(0),
      _contract: _contract,
      _amountIn: _amountIn,
      _amountRefunded: refund
    });
  }

  /**
   * @notice `uniswapTokenToEthAndCall` for when the exact price is not known until the block is mined.
   * @param _priceCallData must return the exact cost as a uint.
   */
  function uniswapTokenToEthAndCallDynamicPrice(
    IERC20 _sourceToken,
    uint _amountIn,
    address _contract,
    bytes memory _priceCallData,
    bytes memory _callData
  ) public
  {
    uint price = _contract._readUint(_priceCallData);
    uniswapTokenToEthAndCall(_sourceToken, _amountIn, price, _contract, _callData);
  }
}
