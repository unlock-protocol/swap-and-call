pragma solidity ^0.5.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
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
  using CallContract for address;

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

    exchange.ethToTokenSwapOutput.value(address(this).balance)(_targetAmount, uint(-1));

    _targetToken.approve(_contract, _targetAmount);
    _contract._call(_callData, 0);
    require(_targetToken.balanceOf(address(this)) == 0, 'INCORRECT_TARGET_AMOUNT');

    uint refund = address(this).balance;
    if(refund > Gas.gasPrice() * 21000)
    {
      msg.sender.transfer(refund);
    }
    else
    {
      // It's not worth the gas cost to refund so leave the ETH here as a donation to the next user
      refund = 0;
    }

    emit SwapAndCall(
      msg.sender,
      address(0),
      address(_targetToken),
      _contract,
      msg.value,
      refund
    );
  }

  function uniswapEthAndCall(
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
    uint refund = 0;
    // TODO

    emit SwapAndCall(
      msg.sender,
      address(_sourceToken),
      address(_targetToken),
      _contract,
      _amountIn,
      refund
    );
  }

  function uniswapTokenAndCall(
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
    uint refund = 0;
    // TODO

    emit SwapAndCall(
      msg.sender,
      address(_sourceToken),
      address(0),
      _contract,
      _amountIn,
      refund
    );
  }

  function uniswapTokenToEthAndCall(
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
