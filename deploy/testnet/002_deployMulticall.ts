import { HardhatRuntimeEnvironment } from 'hardhat/types'
import { DeployFunction } from 'hardhat-deploy/types'

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre
  const { deploy, get, getOrNull, log } = deployments

  const { deployer } = await getNamedAccounts()
  const Multicall = await getOrNull('Multicall')

  if (Multicall) {
    log(`reusing Multicall at ${Multicall.address}`)
  } else {
    await deploy('Multicall', {
      from: deployer,
      log: true,
    })
  }
}
export default func
