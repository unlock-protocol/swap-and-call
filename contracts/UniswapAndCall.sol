pragma solidity ^0.5.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import 'hardlydifficult-ethereum-contracts/contracts/interfaces/IUniswapFactory.sol';
import 'hardlydifficult-ethereum-contracts/contracts/interfaces/IUniswapExchange.sol';
import 'hardlydifficult-ethereum-contracts/contracts/proxies/CallContract.sol';


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
    bool _swapBack,
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
   * either ETH or tokens.
   * @param _token The ERC-20 token address to get from swapping out the ETH provided.
   * @param _swapBack If true then any tokens remaining are swapped back to ETH and
   * then ETH is refunded. Else any refund will be in the target _token type.
   */
  function uniswapEthAndCall(
    IERC20 _token,
    address _contract,
    bytes memory _callData,
    bool _swapBack
  ) public payable
    nonReentrant()
  {
    // Lookup the exchange address for the target token type
    IUniswapExchange exchange = IUniswapExchange(
      uniswapFactory.getExchange(address(_token))
    );

    // Swap ether for tokens passing the entire contract balance (which will typically == msg.value)
    // We swap all ETH instead of a target Output amount since for some use cases the
    // exact number of tokens the 3rd party contract expects when this is mined may not be known.
    exchange.ethToTokenSwapInput.value(address(this).balance)(1, uint(-1));

    // Approve the 3rd party contract to spend the newly aquired tokens
    // TODO: could save ~25k gas by pre-approving once for all users
    _token.approve(_contract, uint(-1)); // Costs 24,966 gas
    // Call the 3rd party contract. This is expected to consume some or all of our tokens (but may not)
    // If the call reverts then this entire transaction will revert and ETH is refunded.
    _contract._call(0, _callData);

    uint refund = 0;

    // Check for any unspent tokens to refund
    uint balance = _token.balanceOf(address(this));
    if(balance > 0)
    {
      if(_swapBack)
      {
        refund = exchange.getTokenToEthInputPrice(balance);
        if(refund > 0) // TODO maybe consider >= minEstimatedGas * gasPrice
        {
          // If we can get at least a wei for it, let's sell and refund the remainder
          // Approve spending enabling the swap back feature
          // TODO: could save ~25k gas by pre-approving once for all users
          _token.approve(address(exchange), uint(-1));
          exchange.tokenToEthSwapInput(balance, 1, uint(-1));

          // Refund any ETH collected from the swap back
          refund = address(this).balance;
          if(refund > 0) // TODO maybe consider >= minEstimatedGas * gasPrice
          {
            msg.sender.transfer(refund);
          }
        }
        /**
        * At this point any tokens remaining in the contract should be worthless dust.
        *
        * It's not worth the gas to return them, so they remain here as a donation
        * to the next user.
        */
      }
      else
      {
        refund = balance;
        // Send any tokens remaining back to the msg.sender.
        _token.transfer(msg.sender, refund);
      }
    }

    emit SwapAndCall(
      msg.sender,
      address(0),
      address(_token),
      _contract,
      msg.value,
      _swapBack,
      refund
    );
  }

  // TODO add support for Token -> ETH and Token -> Token swap then call
}
