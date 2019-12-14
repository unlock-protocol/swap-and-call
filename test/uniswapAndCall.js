const BigNumber = require("bignumber.js");
const { protocols, tokens } = require("hardlydifficult-ethereum-contracts");
const UniswapAndCall = artifacts.require("UniswapAndCall.sol");
const truffleAssert = require("truffle-assertions");

contract("uniswapAndCall", accounts => {
  const owner = accounts[0];
  const keyPrice = web3.utils.toWei("0.00042", "ether");
  let token;
  let exchange;
  let lock;
  let uniswapAndCall;

  beforeEach(async () => {
    // Token
    token = await tokens.sai.deploy(web3, owner);

    // Uniswap exchange with liquidity for testing
    const uniswap = await protocols.uniswap.deploy(web3, owner);
    let tx = await uniswap.createExchange(token.address, {
      from: owner
    });
    exchange = await protocols.uniswap.getExchange(
      web3,
      tx.logs[0].args.exchange
    );
    await token.mint(owner, "1000000000000000000000000", { from: owner });
    await token.approve(exchange.address, -1, { from: owner });
    await exchange.addLiquidity(
      "1",
      "1000000000000000000000000",
      Math.round(Date.now() / 1000) + 60,
      {
        from: owner,
        value: web3.utils.toWei("1", "ether")
      }
    );

    // Lock priced in ERC-20 tokens
    const unlockProtocol = await protocols.unlock.deploy(web3, owner);
    tx = await unlockProtocol.createLock(
      60 * 60 * 24, // expirationDuration (in seconds) of 1 day
      token.address,
      keyPrice,
      100, // maxNumberOfKeys
      "Test Lock", // lockName
      {
        from: owner
      }
    );
    lock = await protocols.unlock.getLock(web3, tx.logs[1].args.newLockAddress);

    // UniswapAndCall
    uniswapAndCall = await UniswapAndCall.new(uniswap.address);
  });

  it("Sanity check: Can't purchase keys with ether", async () => {
    await truffleAssert.fails(
      lock.purchaseFor(accounts[2], {
        from: accounts[2],
        value: await exchange.getEthToTokenOutputPrice(keyPrice)
      })
    );
  });

  describe("Purchase with tokens", () => {
    beforeEach(async () => {
      await token.mint(accounts[2], "1000000000000000000000000", {
        from: owner
      });
      await token.approve(lock.address, -1, { from: accounts[2] });
    });

    it("Sanity check: Can purchase keys with tokens", async () => {
      await lock.purchaseFor(accounts[2], {
        from: accounts[2]
      });
    });
  });

  it("Can purchase keys with ether via UniswapAndCall", async () => {
    const callData = web3.eth.abi.encodeFunctionCall(
      lock.abi.find(e => e.name === "purchaseFor"),
      [accounts[2]]
    );
    await uniswapAndCall.uniswapEthAndCall(
      token.address,
      keyPrice,
      lock.address,
      callData,
      {
        from: accounts[2],
        value: new BigNumber(await exchange.getEthToTokenOutputPrice(keyPrice))
          .times(1.1)
          .dp(0, BigNumber.ROUND_UP)
      }
    );

    const hasKey = await lock.getHasValidKey(accounts[2]);
    assert.equal(hasKey, true);
  });
});
