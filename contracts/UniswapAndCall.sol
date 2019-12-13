pragma solidity ^0.5.0;

import '@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts-ethereum-package/contracts/utils/Address.sol';
import 'hardlydifficult-ethereum-contracts/contracts/interfaces/IUniswapFactory.sol';
import 'hardlydifficult-ethereum-contracts/contracts/interfaces/IUniswapExchange.sol';
import 'hardlydifficult-ethereum-contracts/contracts/proxies/CallContract.sol';


/**
 * @title Uniswap tokens and call contract.
 * @notice Swaps tokens with Uniswap, calls another contract with approval to spend
 * the tokens, and then refunds anything remaining.
 */
contract UniswapAndCall
{
  using Address for address;
  using CallContract for address;

  /**
   * @notice The Uniswap factory for this network.
   * @dev Used to lookup the exchange address for a given token.
   */
  IUniswapFactory public uniswapFactory;

  // TODO maybe we cache exchanges with approvals already set.
  // Safe because it's looked up from the trusted factory.

  // TODO do we maybe also cache the contact (lock address)? to save approvals.
  // Not safe? Call lock, calls hook, reenter, steal refund
  // Would need to clean up approvals to make this safe?
  // Add a re-entrancy block? Overkill?

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
    bool _swapBack,
    address _contract,
    bytes memory _callData
  ) public payable
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
    _token.approve(_contract, uint(-1));
    // Call the 3rd party contract. This is expected to consume some or all of our tokens (but may not)
    // If the call reverts then this entire transaction will revert and ETH is refunded.
    _contract._call(0, _callData);

    // Check for any unspent tokens, this is only applicable if the _contract is not predictable
    // or if tokens remain in the contract from a previous user
    uint balance = _token.balanceOf(address(this));
    if(balance > 0)
    {
      if(_swapBack)
      {
        uint value = exchange.getTokenToEthInputPrice(balance);
        if(value > 0) // TODO change to >= minEstimatedGas * gasPrice
        {
          // If we can get at least a wei for it, let's sell and refund the remainder
          _token.approve(address(exchange), balance);
          exchange.tokenToEthSwapInput(balance, 1, uint(-1));

          // Refund any ETH collected from the swap back
          value = address(this).balance;
          if(value > 0) // TODO change to >= minEstimatedGas * gasPrice
          {
            msg.sender.transfer(value);
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
        // Send any tokens remaining back to the msg.sender.
        _token.transfer(msg.sender, balance);
      }
    }
  }

  // TODO add support for Token -> ETH and Token -> Token swap then call
}
