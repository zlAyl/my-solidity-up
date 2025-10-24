// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract AdvancedMintingSystem is ERC721, Ownable {
    //using Counters for Counters.Counter;
    
    // 代币计数器
    uint256 private _tokenIdCounter;
    
    // 动态铸造权限相关
    mapping(address => bool) private _minters;
    bytes32 public merkleRoot; // 用于白名单验证
    
    // 防女巫攻击
    mapping(address => uint256) private _mintedCount;
    uint256 public maxMintPerAddress = 1;
    
    // 元数据动态生成
    string private _baseTokenURI;
    mapping(uint256 => string) private _tokenAttributes;
    
    // 铸造价格
    uint256 public mintPrice = 0.05 ether;
    
    // 事件
    event MintPermissionUpdated(address indexed minter, bool allowed);
    event MerkleRootUpdated(bytes32 newRoot);
    event MetadataUpdated(uint256 tokenId, string attributes);
    
    constructor(string memory name, string memory symbol) ERC721(name, symbol) Ownable(msg.sender) {
        
    }
    
    // ========== 动态铸造权限管理 ==========
    
    // 设置Merkle Root用于白名单验证
    function setMerkleRoot(bytes32 root) external onlyOwner {
        merkleRoot = root;
        emit MerkleRootUpdated(root);
    }
    
    // 添加/移除铸造权限
    function setMinter(address minter, bool allowed) external onlyOwner {
        _minters[minter] = allowed;
        emit MintPermissionUpdated(minter, allowed);
    }
    
    // 验证铸造权限
    modifier onlyMinter(bytes32[] calldata proof) {
        require(
            _minters[msg.sender] || 
            MerkleProof.verify(proof, merkleRoot, keccak256(abi.encodePacked(msg.sender))),
            "Caller is not allowed to mint"
        );
        _;
    }
    
    // ========== 防女巫攻击 ==========
    
    // 设置每个地址最大铸造量
    function setMaxMintPerAddress(uint256 max) external onlyOwner {
        maxMintPerAddress = max;
    }
    
    // 检查是否超过最大铸造量
    modifier checkMintLimit() {
        require(
            _mintedCount[msg.sender] < maxMintPerAddress,
            "Exceeds maximum mint limit per address"
        );
        _;
        _mintedCount[msg.sender]++;
    }
    
    // ========== 元数据动态生成 ==========
    
    // 设置基础URI
    function setBaseURI(string calldata baseURI) external onlyOwner {
        _baseTokenURI = baseURI;
    }
    
    // 设置代币属性(可扩展为链上或链下生成)
    function setTokenAttributes(uint256 tokenId, string calldata attributes) external {
        //require(_isApprovedOrOwner(msg.sender, tokenId), "Not owner nor approved");
        _tokenAttributes[tokenId] = attributes;
        emit MetadataUpdated(tokenId, attributes);
    }
    
    // 重写tokenURI方法实现动态元数据
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        string memory baseURI = _baseURI();
        string memory attributes = _tokenAttributes[tokenId];
        
        if(bytes(attributes).length > 0) {
            return string(abi.encodePacked(baseURI, Strings.toString(tokenId), "?attributes=", attributes));
        }
        return string(abi.encodePacked(baseURI, Strings.toString(tokenId)));
    }
    
    // ========== 铸造功能 ==========
    
    // 公开铸造函数
    function mint(bytes32[] calldata proof, string calldata initialAttributes) 
        external 
        payable 
        onlyMinter(proof)
        checkMintLimit
    {
        require(msg.value >= mintPrice, "Insufficient payment");
        
        uint256 tokenId = _tokenIdCounter;
        _tokenIdCounter++;
        _safeMint(msg.sender, tokenId);
        
        if(bytes(initialAttributes).length > 0) {
            _tokenAttributes[tokenId] = initialAttributes;
        }
    }
    
    // 提取资金
    function withdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
}