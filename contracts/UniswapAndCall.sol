pragma solidity ^0.5.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import 'hardlydifficult-ethereum-contracts/contracts/interfaces/IUniswapFactory.sol';
import 'hardlydifficult-ethereum-contracts/contracts/interfaces/IUniswapExchange.sol';
import 'hardlydifficult-ethereum-contracts/contracts/proxies/CallContract.sol';
import 'hardlydifficult-ethereum-contracts/contracts/utils/Gas.sol';


/**
 * @title Uniswap tokens and call contract.
 * @notice Swaps tokens with Uniswap, calls another contract with approval to spend
 * the tokens, and then refunds anything remaining.
 */
contract UniswapAndCall is
  ReentrancyGuard
{
  using Address for address;
  using Address for address payable;
  using CallContract for address;
  using SafeERC20 for IERC20;

  /**
   * @notice The Uniswap factory for this network.
   * @dev Used to lookup the exchange address for a given token.
   */
  IUniswapFactory public uniswapFactory;

  event SwapAndCall(
    address indexed _sender,
    address _fromToken,
    address _toToken,
    address indexed _contract,
    uint _amountIn,
    uint _amountRefunded
  );

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

    // The 3rd party contract must consume all the tokens we swapped for
    require(_targetToken.balanceOf(address(this)) == 0, 'INCORRECT_TARGET_AMOUNT');
  }

  /**
   * @notice Swap ETH for the token a contract expects, make the call, and then refund
   * any ETH remaining.
   * @param _targetToken The ERC-20 token address to get from swapping out the ETH provided.
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
    if(refund > Gas.gasPrice() * 21000)
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

  function uniswapTokenToEthAndCall(
    IERC20 _sourceToken,
    uint _amountIn,
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
    exchange.tokenToEthSwapOutput(_targetAmount, uint(-1), uint(-1));

    // Call the 3rd party contract
    _contract._call(_callData, _targetAmount);

    // The 3rd party contract must consume all the tokens we swapped for
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
