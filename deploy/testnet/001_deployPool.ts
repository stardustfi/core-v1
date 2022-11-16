import { HardhatRuntimeEnvironment } from 'hardhat/types'
import { DeployFunction } from 'hardhat-deploy/types'

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre
  const { deploy, execute, get, getOrNull, log } = deployments

  const { deployer, account2 } = await getNamedAccounts()
  const Pool = await getOrNull('Pool')
  const tokens = [
    ['1000000000000000000000000000', 'cbETH', 'cbETH', '18'],
    ['1000000000000000000000000000', 'vlCVX', 'vlCVX', '18'],
    ['100000000000000000000', 'USDC', 'USDC', '6'],
  ]

  for (let i = 0; i < tokens.length; i++) {
    let [supply, name, symbol, decimals] = [
      tokens[i][0],
      tokens[i][1],
      tokens[i][2],
      tokens[i][3],
    ]
    const token = await getOrNull(symbol)
    if (token) {
      log(`reusing ` + symbol + ` at ${token.address}`)
    } else {
      await deploy(symbol, {
        from: deployer,
        log: true,
        contract: 'GenericERC20',
        args: [supply, name, symbol, decimals],
      })

      await execute(
        symbol,
        { from: deployer },
        'mint',
        account2,
        '1000000000000000000000',
      )
    }
  }
  if (Pool) {
    log(`reusing Pool at ${Pool.address}`)
  } else {
    await deploy('Pool', {
      from: deployer,
      log: true,
      args: [(await get('USDC')).address],
    })
  }
}
export default func
