pragma solidity ^0.6.10;

/**
 * @title iService interface
 */
interface iServiceInterface {
    /**
     * @dev Initiate a service invocation
     * @param _serviceName Service name
     * @param _input Request input
     * @param _timeout Request timeout
     * @param _callbackAddress Callback contract address
     * @param _callbackFunction Callback function selector
     * @return requestID Request id
     */
    function callService(
        string calldata _serviceName,
        string calldata _input,
        uint256 _timeout,
        address _callbackAddress,
        bytes4 _callbackFunction
    ) external returns (bytes32 requestID);

    /**
     * @dev Set the response of the specified service request
     * @param _requestID Request id
     * @param _errMsg Error message of the service invocation
     * @param _output Response output
     * @param _icRequestID Request id on Irita-Hub
     * @return True on success, false otherwise
     */
    function setResponse(
        bytes32 _requestID,
        string calldata _errMsg,
        string calldata _output,
        string calldata _icRequestID
    ) external returns (bool);
}

/*
 * @title Contract for the iService core extension client
 */
contract iServiceClient {
    iServiceInterface iServiceCore; // iService Core contract address

    // mapping the request id to Request
    mapping(bytes32 => Request) requests;
    
    // request
    struct Request {
        address callbackAddress; // callback contract address
        bytes4 callbackFunction; // callback function selector
        bool sent; // request sent
        bool responded; // request responded
    }

    /*
     * @dev Event triggered when the iService request is sent
     * @param _requestID Request id
     */
    event RequestSent(bytes32 _requestID);
    
    /*
     * @dev Make sure that the sender is the contract itself
     * @param _requestID Request id
     */
    modifier onlySelf() {
        require(msg.sender == address(this), "iServiceClient: sender must be the contract itself");
        
        _;
    }

    /*
     * @dev Make sure that the given request is valid
     * @param _requestID Request id
     */
    modifier validRequest(bytes32 _requestID) {
        require(requests[_requestID].sent, "iServiceClient: request does not exist");
        require(!requests[_requestID].responded, "iServiceClient: request has been responded");
        
        _;
    }
    
    /*
     * @dev Send the iService request
     * @param _serviceName Service name
     * @param _input Service request input
     * @param _timeout Service request timeout
     * @param _callbackAddress Callback contract address
     * @param _callbackFunction Callback function selector
     * @return requestID Request id
     */
    function sendIServiceRequest(
        string memory _serviceName,
        string memory _input,
        uint256 _timeout,
        address _callbackAddress,
        bytes4 _callbackFunction
    )
        internal
        returns (bytes32 requestID)
    {
        requestID = iServiceCore.callService(_serviceName, _input, _timeout, address(this), this.onResponse.selector);
        
        Request memory request = Request(
            _callbackAddress,
            _callbackFunction,
            true,
            false
        );

        requests[requestID] = request;

        emit RequestSent(requestID);
        
        return requestID;
    }

    /* 
     * @dev Callback function
     * @param _requestID Request id
     * @param _output Response output
     */
    function onResponse(
        bytes32 _requestID,
        string calldata _output
    )
        external
        validRequest(_requestID)
    {
        requests[_requestID].responded = true;
        
        address cbAddr = requests[_requestID].callbackAddress;
        bytes4 cbFunc = requests[_requestID].callbackFunction;
        
        cbAddr.call(abi.encodeWithSelector(cbFunc, _requestID, _output));
    }

    /**
     * @dev Set the iService core contract address
     * @param _iServiceCore Address of the iService core contract
     */
    function setIServiceCore(address _iServiceCore) internal {
        require(_iServiceCore != address(0), "iServiceClient: iService core address can not be zero");
        iServiceCore = iServiceInterface(_iServiceCore);
    }
}

/*
 * @title Contract for inter-chain NFT minting powered by iService
 * The service is supported by price service
 */
contract NFTServiceConsumer is iServiceClient {
    // price service variables
    string private priceServiceName = "oracle-price"; // price service name
    string private priceRequestInput = '{"header":{},"body":{"pair":"usdt-eth"}}'; // price request input

    // nft service variables
    string private nftServiceName = "fisco-contract-call"; // nft service name
    address private to;
    uint256 private amount;
    string private metaID;
    uint256 private setPrice;
    bool private isForSale;
    
    uint256 public rate; // rate for usdt against eth
    string public nftID; // id of the minted nft

    uint256 private defaultTimeout = 100; // maximum number of irita-hub blocks to wait for; default to 100
    
    /*
     * @notice Event triggered when the nft is minted
     * @param _requestID Request id
     * @param _nftID NFT id
     */
    event NFTMinted(bytes32 _requestID, string _nftID);
    
    /*
     * @notice Event triggered when the price is set
     * @param _requestID Request id
     * @param _price Price
     */
    event PriceSet(bytes32 _requestID, string _price);

    /*
     * @notice Constructor
     * @param _iServiceContract Address of the iService contract
     * @param _defaultTimeout Default service request timeout
     */
    constructor(
        address _iServiceCore,
        uint256 _defaultTimeout
    )
        public
    {
        setIServiceCore(_iServiceCore);
        
        if (_defaultTimeout > 0) {
            defaultTimeout = _defaultTimeout;
        }
    }

    /*
     * @notice Start workflow for minting nft
     * @param _to Destination address to mint to
     * @param _amount Amount of NFTs to be minted
     * @param _metaID Meta id
     * @param _setPrice Price
     * @param _isForSale Whether or not for sale
     */
    function mint (
        address _to,
        uint256 _amount,
        string calldata _metaID,
        uint256 _setPrice,
        bool _isForSale
    )
        external
    {
        to = _to;
        amount = _amount;
        metaID = _metaID;
        setPrice = _setPrice;
        isForSale = _isForSale;

        _requestPrice();
    }

    /*
     * @notice Start workflow for minting nft
     * @param _args String arguments for minting nft
     */
    function mintV2(
        string calldata _args
    )
        external
    {
        sendIServiceRequest(
            nftServiceName,
            _args,
            defaultTimeout,
            address(this),
            this.onNFTMinted.selector
        );
    }

    /*
     * @notice Request Eth price for minting NFT 
     */
    function _requestPrice () internal {
        sendIServiceRequest(
            priceServiceName,
            priceRequestInput,
            defaultTimeout,
            address(this),
            this.onPriceSet.selector
        );
    }

    /*
     * @notice Request to mint an NFT 
     */
    function _requestMint () internal {
        setPrice *= rate; // compute the eth price according to the usdt-eth rate
        string memory nftRequestInput = _buildMintRequest(to, amount, metaID, setPrice, isForSale);
        
        sendIServiceRequest(
            nftServiceName,
            nftRequestInput,
            defaultTimeout,
            address(this),
            this.onNFTMinted.selector
        );
    }

    /* 
     * @notice Price service callback function
     * @param _requestID Request id
     * @param _output Price service response output
     */
    function onPriceSet(
        bytes32 _requestID,
        string calldata _output
    )
        external
        validRequest(_requestID)
    {
        string memory price = _parsePrice(_output);
        
        emit PriceSet(_requestID, price);

        rate = uint256(JsmnSolLib.parseInt(price, 18));

        _requestMint();
    }

    /* 
     * @notice NFT service callback function
     * @param _requestID Request id
     * @param _output NFT service response output
     */
    function onNFTMinted(
        bytes32 _requestID,
        string calldata _output
    )
        external
        validRequest(_requestID)
    {
        nftID = _parseNFTID(_output);

        emit NFTMinted(_requestID, nftID);
    }
    
    /*
     * @notice Parse the price from output
     * @param _output Price service response output
     */
    function _parsePrice(
        string memory _output
    ) 
        internal
        pure
        returns (string memory)
    {
        return _parseJSON(_output, 10, 4);
    }
    
     /*
     * @notice Parse the NFT id from output
     * @param _output NFT service response output
     */
    function _parseNFTID(
        string memory _output
    ) 
        internal
        pure
        returns (string memory)
    {
        return _parseJSON(_output, 10, 6);
    }
    
    /*
     * @notice Build the nft minting request
     * @param _to Destination address to mint to
     * @param _amount Amount of NFTs to be minted
     * @param _metaID Meta id
     * @param _setPrice Price
     * @param _isForSale Whether or not for sale
     */
    function _buildMintRequest(
        address _to,
        uint256 _amount,
        string memory _metaID,
        uint256 _setPrice,
        bool _isForSale
    )
        internal
        pure
        returns (string memory)
    {
        // string memory abiEncoded = string(abi.encodePacked(_to, _amount, _metaID, _setPrice, _isForSale));
        // return _strConcat(_strConcat('{"header":{},"body":{"abi_encoded":"0x', abiEncoded),'"}}');
        
        return '{"header":{},"body":{"to":"0xaa27bb5ef6e54a9019be7ade0d0fc514abb4d03b","amount_to_mint":"1","meta_id":"-Z-2fJxzCoFJ0MOU-zA3-tiIh7dK6FjDruAxgxW6PEs","set_price":"2000000000000000","is_for_sale":true}}';
    }

    /*
     * @notice Concatenate two strings into a single string
     * @param _first First string
     * @param _second Second string
     */
    function _strConcat(
        string memory _first, 
        string memory _second
    ) 
        internal
        pure
        returns(string memory)
    {
        bytes memory first = bytes(_first);
        bytes memory second = bytes(_second);
        bytes memory res = new bytes(first.length + second.length);

        for(uint i = 0; i < first.length; i++) {
            res[i] = first[i];
        }

        for(uint j = 0; j < second.length; j++) {
            res[first.length+j] = second[j];
        }

        return string(res);
    }
    
    /*
     * @notice Parse the NFT id from output
     * @param _json JSON to be parsed
     * @param _maxElements Maximum element numbers in JSON
     * @param _pos Position of the element to be parsed
     */
    function _parseJSON(
        string memory _json,
        uint _maxElements,
        uint _pos
    ) 
        internal
        pure
        returns (string memory)
    {
        uint256 returnValue;
        JsmnSolLib.Token[] memory tokens;
        uint actualNum;

        (returnValue, tokens, actualNum) = JsmnSolLib.parse(_json, _maxElements);
        
        require(returnValue == 0 && actualNum >= _pos, "failed to parse json");

        JsmnSolLib.Token memory t = tokens[_pos];
        return JsmnSolLib.getBytes(_json, t.start, t.end);
    }
}

/*
 * @title JSON parser
 */
library JsmnSolLib {

    enum JsmnType { UNDEFINED, OBJECT, ARRAY, STRING, PRIMITIVE }

    uint constant RETURN_SUCCESS = 0;
    uint constant RETURN_ERROR_INVALID_JSON = 1;
    uint constant RETURN_ERROR_PART = 2;
    uint constant RETURN_ERROR_NO_MEM = 3;

    struct Token {
        JsmnType jsmnType;
        uint start;
        bool startSet;
        uint end;
        bool endSet;
        uint8 size;
    }

    struct Parser {
        uint pos;
        uint toknext;
        int toksuper;
    }

    function init(uint length) internal pure returns (Parser memory, Token[] memory) {
        Parser memory p = Parser(0, 0, -1);
        Token[] memory t = new Token[](length);
        return (p, t);
    }

    function allocateToken(Parser memory parser, Token[] memory tokens) internal pure returns (bool, Token memory) {
        if (parser.toknext >= tokens.length) {
            // no more space in tokens
            return (false, tokens[tokens.length-1]);
        }
        Token memory token = Token(JsmnType.UNDEFINED, 0, false, 0, false, 0);
        tokens[parser.toknext] = token;
        parser.toknext++;
        return (true, token);
    }

    function fillToken(Token memory token, JsmnType jsmnType, uint start, uint end) internal pure {
        token.jsmnType = jsmnType;
        token.start = start;
        token.startSet = true;
        token.end = end;
        token.endSet = true;
        token.size = 0;
    }

    function parseString(Parser memory parser, Token[] memory tokens, bytes memory s) internal pure returns (uint) {
        uint start = parser.pos;
        bool success;
        Token memory token;
        parser.pos++;

        for (; parser.pos<s.length; parser.pos++) {
            bytes1 c = s[parser.pos];

            // Quote -> end of string
            if (c == '"') {
                (success, token) = allocateToken(parser, tokens);
                if (!success) {
                    parser.pos = start;
                    return RETURN_ERROR_NO_MEM;
                }
                fillToken(token, JsmnType.STRING, start+1, parser.pos);
                return RETURN_SUCCESS;
            }

            if (uint8(c) == 92 && parser.pos + 1 < s.length) {
                // handle escaped characters: skip over it
                parser.pos++;
                if (s[parser.pos] == '\"' || s[parser.pos] == '/' || s[parser.pos] == '\\'
                    || s[parser.pos] == 'f' || s[parser.pos] == 'r' || s[parser.pos] == 'n'
                    || s[parser.pos] == 'b' || s[parser.pos] == 't') {
                        continue;
                        } else {
                            // all other values are INVALID
                            parser.pos = start;
                            return(RETURN_ERROR_INVALID_JSON);
                        }
                    }
            }
        parser.pos = start;
        return RETURN_ERROR_PART;
    }

    function parsePrimitive(Parser memory parser, Token[] memory tokens, bytes memory s) internal pure returns (uint) {
        bool found = false;
        uint start = parser.pos;
        byte c;
        bool success;
        Token memory token;
        for (; parser.pos < s.length; parser.pos++) {
            c = s[parser.pos];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ','
                || c == 0x7d || c == 0x5d) {
                    found = true;
                    break;
            }
            if (uint8(c) < 32 || uint8(c) > 127) {
                parser.pos = start;
                return RETURN_ERROR_INVALID_JSON;
            }
        }
        if (!found) {
            parser.pos = start;
            return RETURN_ERROR_PART;
        }

        // found the end
        (success, token) = allocateToken(parser, tokens);
        if (!success) {
            parser.pos = start;
            return RETURN_ERROR_NO_MEM;
        }
        fillToken(token, JsmnType.PRIMITIVE, start, parser.pos);
        parser.pos--;
        return RETURN_SUCCESS;
    }

    function parse(string memory json, uint numberElements) internal pure returns (uint, Token[] memory tokens, uint) {
        bytes memory s = bytes(json);
        bool success;
        Parser memory parser;
        (parser, tokens) = init(numberElements);

        // Token memory token;
        uint r;
        uint count = parser.toknext;
        uint i;
        Token memory token;

        for (; parser.pos<s.length; parser.pos++) {
            bytes1 c = s[parser.pos];

            // 0x7b, 0x5b opening curly parentheses or brackets
            if (c == 0x7b || c == 0x5b) {
                count++;
                (success, token) = allocateToken(parser, tokens);
                if (!success) {
                    return (RETURN_ERROR_NO_MEM, tokens, 0);
                }
                if (parser.toksuper != -1) {
                    tokens[uint(parser.toksuper)].size++;
                }
                token.jsmnType = (c == 0x7b ? JsmnType.OBJECT : JsmnType.ARRAY);
                token.start = parser.pos;
                token.startSet = true;
                parser.toksuper = int(parser.toknext - 1);
                continue;
            }

            // closing curly parentheses or brackets
            if (c == 0x7d || c == 0x5d) {
                JsmnType tokenType = (c == 0x7d ? JsmnType.OBJECT : JsmnType.ARRAY);
                bool isUpdated = false;
                for (i=parser.toknext-1; i>=0; i--) {
                    token = tokens[i];
                    if (token.startSet && !token.endSet) {
                        if (token.jsmnType != tokenType) {
                            // found a token that hasn't been closed but from a different type
                            return (RETURN_ERROR_INVALID_JSON, tokens, 0);
                        }
                        parser.toksuper = -1;
                        tokens[i].end = parser.pos + 1;
                        tokens[i].endSet = true;
                        isUpdated = true;
                        break;
                    }
                }
                if (!isUpdated) {
                    return (RETURN_ERROR_INVALID_JSON, tokens, 0);
                }
                for (; i>0; i--) {
                    token = tokens[i];
                    if (token.startSet && !token.endSet) {
                        parser.toksuper = int(i);
                        break;
                    }
                }

                if (i==0) {
                    token = tokens[i];
                    if (token.startSet && !token.endSet) {
                        parser.toksuper = uint128(i);
                    }
                }
                continue;
            }

            // 0x42
            if (c == '"') {
                r = parseString(parser, tokens, s);

                if (r != RETURN_SUCCESS) {
                    return (r, tokens, 0);
                }
                //JsmnError.INVALID;
                count++;
				if (parser.toksuper != -1)
					tokens[uint(parser.toksuper)].size++;
                continue;
            }

            // ' ', \r, \t, \n
            if (c == ' ' || c == 0x11 || c == 0x12 || c == 0x14) {
                continue;
            }

            // 0x3a
            if (c == ':') {
                parser.toksuper = int(parser.toknext -1);
                continue;
            }

            if (c == ',') {
                if (parser.toksuper != -1
                    && tokens[uint(parser.toksuper)].jsmnType != JsmnType.ARRAY
                    && tokens[uint(parser.toksuper)].jsmnType != JsmnType.OBJECT) {
                        for(i = parser.toknext-1; i>=0; i--) {
                            if (tokens[i].jsmnType == JsmnType.ARRAY || tokens[i].jsmnType == JsmnType.OBJECT) {
                                if (tokens[i].startSet && !tokens[i].endSet) {
                                    parser.toksuper = int(i);
                                    break;
                                }
                            }
                        }
                    }
                continue;
            }

            // Primitive
            if ((c >= '0' && c <= '9') || c == '-' || c == 'f' || c == 't' || c == 'n') {
                if (parser.toksuper != -1) {
                    token = tokens[uint(parser.toksuper)];
                    if (token.jsmnType == JsmnType.OBJECT
                        || (token.jsmnType == JsmnType.STRING && token.size != 0)) {
                            return (RETURN_ERROR_INVALID_JSON, tokens, 0);
                        }
                }

                r = parsePrimitive(parser, tokens, s);
                if (r != RETURN_SUCCESS) {
                    return (r, tokens, 0);
                }
                count++;
                if (parser.toksuper != -1) {
                    tokens[uint(parser.toksuper)].size++;
                }
                continue;
            }

            // printable char
            if (c >= 0x20 && c <= 0x7e) {
                return (RETURN_ERROR_INVALID_JSON, tokens, 0);
            }
        }

        return (RETURN_SUCCESS, tokens, parser.toknext);
    }

    function getBytes(string memory json, uint start, uint end) internal pure returns (string memory) {
        bytes memory s = bytes(json);
        bytes memory result = new bytes(end-start);
        for (uint i=start; i<end; i++) {
            result[i-start] = s[i];
        }
        return string(result);
    }

    // parseInt
    function parseInt(string memory _a) internal pure returns (int) {
        return parseInt(_a, 0);
    }

    // parseInt(parseFloat*10^_b)
    function parseInt(string memory _a, uint _b) internal pure returns (int) {
        bytes memory bresult = bytes(_a);
        int mint = 0;
        bool decimals = false;
        bool negative = false;
        for (uint i=0; i<bresult.length; i++){
            if ((i == 0) && (bresult[i] == '-')) {
                negative = true;
            }
            if ((uint8(bresult[i]) >= 48) && (uint8(bresult[i]) <= 57)) {
                if (decimals){
                   if (_b == 0) break;
                    else _b--;
                }
                mint *= 10;
                mint += uint8(bresult[i]) - 48;
            } else if (uint8(bresult[i]) == 46) decimals = true;
        }
        if (_b > 0) mint *= int(10**_b);
        if (negative) mint *= -1;
        return mint;
    }

    function uint2str(uint i) internal pure returns (string memory){
        if (i == 0) return "0";
        uint j = i;
        uint len;
        while (j != 0){
            len++; 
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint k = len - 1;
        while (i != 0){
            bstr[k--] = bytes1(uint8(48 + i % 10));
            i /= 10;
        }
        return string(bstr);
    }

    function parseBool(string memory _a) internal pure returns (bool) {
        if (strCompare(_a, 'true') == 0) {
            return true;
        } else {
            return false;
        }
    }

    function strCompare(string memory _a, string memory _b) internal pure returns (int) {
        bytes memory a = bytes(_a);
        bytes memory b = bytes(_b);
        uint minLength = a.length;
        if (b.length < minLength) minLength = b.length;
        for (uint i = 0; i < minLength; i ++)
            if (a[i] < b[i])
                return -1;
            else if (a[i] > b[i])
                return 1;
        if (a.length < b.length)
            return -1;
        else if (a.length > b.length)
            return 1;
        else
            return 0;
    }
}
