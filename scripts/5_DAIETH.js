const { ethers } = require("hardhat")
const { mainnet } = require("../addresses")

const sushiFactoryAddr = "0xA9A09D4F4382c147E314381918F2da703ea1a911"

async function main() {
    const [deployer] = await ethers.getSigners()

    // const sushiVaultArtifact = await artifacts.readArtifact("Sushi")
    const sushiVaultArtifact = await artifacts.readArtifact("SushiKovan")
    const sushiVaultInterface = new ethers.utils.Interface(sushiVaultArtifact.abi)
    const dataDAIETH = sushiVaultInterface.encodeFunctionData(
        "initialize",
        [
            "DAO L1 Sushi DAI-ETH", "daoSushiDAI", 2,
            mainnet.treasury, mainnet.community, mainnet.strategist, mainnet.admin
        ]
    )
    const sushiFactory = await ethers.getContractAt("SushiFactory", sushiFactoryAddr, deployer)
    const tx = await sushiFactory.createVault(dataDAIETH)
    await tx.wait()
    const DAIETHVaultAddr = await sushiFactory.getVault((await sushiFactory.getVaultLength()).sub(1))

    console.log("Sushi DAI-ETH vault (proxy) contract address:", DAIETHVaultAddr)
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error)
        process.exit(1)
    })