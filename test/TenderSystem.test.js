const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("Tender System", function () {
    let Factory;
    let Tender;
    let factory;
    let tenderMaster;
    let owner;
    let organization;
    let bidder1;
    let bidder2;
    let bidder3;

    const REQUIRED_STAKE = ethers.parseEther("0.1");
    const MIN_STAKE_AMOUNT = ethers.parseEther("1.0");
    
    beforeEach(async function () {
        [owner, organization, bidder1, bidder2, bidder3] = await ethers.getSigners();

        // Deploy TenderContract master
        Tender = await ethers.getContractFactory("TenderContract");
        tenderMaster = await Tender.deploy();
        await tenderMaster.waitForDeployment();

        // Deploy Factory
        Factory = await ethers.getContractFactory("FactoryContract");
        factory = await Factory.deploy();
        await factory.waitForDeployment();

        // Initialize Factory
        await factory.initialize(await tenderMaster.getAddress());

        // Setup roles
        const ADMIN_ROLE = await factory.ADMIN_ROLE();
        const ORGANIZATION_ROLE = await factory.ORGANIZATION_ROLE();
        
        await factory.grantRole(ORGANIZATION_ROLE, organization.address);
    });

    describe("Factory Contract", function () {
        it("Should initialize correctly", async function () {
            expect(await factory.tenderImplementation()).to.equal(await tenderMaster.getAddress());
        });

        it("Should register bidder with stake", async function () {
            await factory.connect(bidder1).registerBidder("bidder1_metadata", { value: MIN_STAKE_AMOUNT });
            
            const profile = await factory.getUserProfile(bidder1.address);
            expect(profile.stakedAmount).to.equal(MIN_STAKE_AMOUNT);
            expect(await factory.hasRole(await factory.BIDDER_ROLE(), bidder1.address)).to.be.true;
        });

        it("Should not register bidder with insufficient stake", async function () {
            await expect(
                factory.connect(bidder1).registerBidder("bidder1_metadata", { value: ethers.parseEther("0.5") })
            ).to.be.revertedWith("Insufficient stake amount");
        });
    });

    describe("Tender Creation and Management", function () {
        beforeEach(async function () {
            // Register bidders
            await factory.connect(bidder1).registerBidder("bidder1_metadata", { value: MIN_STAKE_AMOUNT });
            await factory.connect(bidder2).registerBidder("bidder2_metadata", { value: MIN_STAKE_AMOUNT });
            await factory.connect(bidder3).registerBidder("bidder3_metadata", { value: MIN_STAKE_AMOUNT });
        });

        it("Should deploy and initialize new tender", async function () {
            const startTime = await time.latest() + 3600; // 1 hour from now
            const endTime = startTime + 86400; // 24 hours after start
            
            const tx = await factory.connect(organization).deployTender(
                "tender_metadata",
                "ipfs_hash",
                startTime,
                endTime,
                ethers.parseEther("1.0"), // minimumBid
                60, // bidWeight
                40  // reputationWeight
            );

            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'TenderDeployed');
            expect(event).to.not.be.undefined;

            const tenderAddress = event.args[0];
            const tender = await ethers.getContractAt("TenderContract", tenderAddress);
            
            const details = await tender.getTenderDetails();
            expect(details.organization).to.equal(organization.address);
            expect(details.status).to.equal(0); // Created status
        });

        it("Should activate tender and accept bids", async function () {
            // Deploy tender
            const startTime = await time.latest() + 3600;
            const endTime = startTime + 86400;
            
            const tx = await factory.connect(organization).deployTender(
                "tender_metadata",
                "ipfs_hash",
                startTime,
                endTime,
                ethers.parseEther("1.0"),
                60,
                40
            );

            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'TenderDeployed');
            const tenderAddress = event.args[0];
            const tender = await ethers.getContractAt("TenderContract", tenderAddress);

            // Activate tender
            await time.increaseTo(startTime);
            await factory.connect(organization).activateTender(tenderAddress);

            // Submit bids
            await tender.connect(bidder1).submitBid(
                ethers.parseEther("2.0"),
                "bid1_ipfs",
                { value: REQUIRED_STAKE }
            );

            const bidDetails = await tender.getBidDetails(bidder1.address);
            expect(bidDetails.amount).to.equal(ethers.parseEther("2.0"));
            expect(bidDetails.status).to.equal(1); // Active status
        });

        it("Should select winner and update analytics", async function () {
            // Deploy and setup tender
            const startTime = await time.latest() + 3600;
            const endTime = startTime + 86400;
            
            const tx = await factory.connect(organization).deployTender(
                "tender_metadata",
                "ipfs_hash",
                startTime,
                endTime,
                ethers.parseEther("1.0"),
                60,
                40
            );

            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'TenderDeployed');
            const tenderAddress = event.args[0];
            const tender = await ethers.getContractAt("TenderContract", tenderAddress);

            // Activate tender
            await time.increaseTo(startTime);
            await factory.connect(organization).activateTender(tenderAddress);

            // Submit multiple bids
            await tender.connect(bidder1).submitBid(
                ethers.parseEther("2.0"),
                "bid1_ipfs",
                { value: REQUIRED_STAKE }
            );
            await tender.connect(bidder2).submitBid(
                ethers.parseEther("1.8"),
                "bid2_ipfs",
                { value: REQUIRED_STAKE }
            );
            await tender.connect(bidder3).submitBid(
                ethers.parseEther("2.2"),
                "bid3_ipfs",
                { value: REQUIRED_STAKE }
            );

            // Move to end time and select winner
            await time.increaseTo(endTime + 1);
            await tender.connect(organization).selectWinner();

            // Verify winner selection and analytics update
            const details = await tender.getTenderDetails();
            expect(details.status).to.equal(2); // Closed status
            expect(details.winner).to.not.equal(ethers.ZeroAddress);

            // Check analytics update
            const analytics = await factory.getUserAnalytics(details.winner);
            expect(analytics.tendersWon).to.equal(1);
            expect(analytics.totalBids).to.equal(1);
        });
    });

    describe("Emergency Handling", function () {
        it("Should handle emergency stop", async function () {
            const startTime = await time.latest() + 3600;
            const endTime = startTime + 86400;
            
            // Deploy tender
            const tx = await factory.connect(organization).deployTender(
                "tender_metadata",
                "ipfs_hash",
                startTime,
                endTime,
                ethers.parseEther("1.0"),
                60,
                40
            );

            const receipt = await tx.wait();
            const event = receipt.logs.find(log => log.fragment && log.fragment.name === 'TenderDeployed');
            const tenderAddress = event.args[0];
            const tender = await ethers.getContractAt("TenderContract", tenderAddress);

            // Trigger emergency stop
            await tender.connect(owner).toggleEmergencyStop("Emergency test");
            
            // Verify operations are blocked
            await expect(
                tender.connect(bidder1).submitBid(
                    ethers.parseEther("2.0"),
                    "bid1_ipfs",
                    { value: REQUIRED_STAKE }
                )
            ).to.be.revertedWith("State error: Contract is in emergency stop");
        });
    });
}); 