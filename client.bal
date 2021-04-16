// Copyright (c) 2019, WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.
//

import ballerina/http;
import ballerina/regex;

# Amazon S3 connector client
# 
# + amazonS3 - HTTP client
public client class Client {
    private string accessKeyId;
    private string secretAccessKey;
    private string region;
    private string amazonHost = EMPTY_STRING;
    public http:Client amazonS3;

    public isolated function init(ClientConfiguration amazonS3Config) returns error? {
        self.region = amazonS3Config.region;
        self.amazonHost = self.region != DEFAULT_REGION ? regex:replaceFirst(AMAZON_AWS_HOST, SERVICE_NAME, 
            SERVICE_NAME + "." + self.region) :  AMAZON_AWS_HOST;
        string baseURL = HTTPS + self.amazonHost;
        self.accessKeyId = amazonS3Config.accessKeyId;
        self.secretAccessKey = amazonS3Config.secretAccessKey;
        check verifyCredentials(self.accessKeyId, self.secretAccessKey);  
        http:ClientSecureSocket? clientSecureSocket = amazonS3Config?.secureSocketConfig;
        if (clientSecureSocket is http:ClientSecureSocket) {
            amazonS3Config.clientConfig.secureSocket = clientSecureSocket;
        }
        self.amazonS3  = check new(baseURL, amazonS3Config.clientConfig);      
    }

    # Retrieves a list of all Amazon S3 buckets that the authenticated user of the request owns.
    # 
    # + return - If success, returns a list of Bucket record, else returns error
    remote function listBuckets() returns @tainted Bucket[]|error {
        map<string> requestHeaders = {
            [HOST]: self.amazonHost,
            [X_AMZ_CONTENT_SHA256]: UNSIGNED_PAYLOAD
        };
        
        check generateSignature(self.accessKeyId, self.secretAccessKey, self.region, GET, SLASH, UNSIGNED_PAYLOAD,
            requestHeaders);

        var httpResponse = self.amazonS3->get(SLASH, requestHeaders);
        if (httpResponse is http:Response) {
            xml xmlPayload = check httpResponse.getXmlPayload();
            if (httpResponse.statusCode == http:STATUS_OK) {
                return getBucketsList(xmlPayload);
            }   
            return error(xmlPayload.toString());                        
        }
        return error(API_INVOCATION_ERROR_MSG + "listing buckets.");
    }

    # Create a bucket.
    # 
    # + bucketName - Unique name for the bucket to create.
    # + cannedACL - The access control list of the new bucket.
    # 
    # + return - If failed turns error.
    remote function createBucket(string bucketName, CannedACL? cannedACL = ()) returns @tainted error? {
        map<string> requestHeaders = {};
        http:Request request = new;
        string requestURI = string `/${bucketName}/`;

        requestHeaders[HOST] = self.amazonHost;
        requestHeaders[X_AMZ_CONTENT_SHA256] = UNSIGNED_PAYLOAD;
        if (cannedACL != ()) {
            requestHeaders[X_AMZ_ACL] = cannedACL.toString();
        }
        if(self.region != DEFAULT_REGION) {
            xml xmlPayload = xml `<CreateBucketConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"> 
                                        <LocationConstraint>${self.region}</LocationConstraint> 
                                </CreateBucketConfiguration>`;   
            request.setXmlPayload(xmlPayload);
        }
        check generateSignature(self.accessKeyId, self.secretAccessKey, self.region, PUT, requestURI, UNSIGNED_PAYLOAD,
            requestHeaders, request);

        var httpResponse = self.amazonS3->put(requestURI, request);
        if (httpResponse is http:Response) {
            return handleHttpResponse(httpResponse);
        }
        return error(API_INVOCATION_ERROR_MSG + "creating bucket.");
    }

    # Retrieve the existing objects in a given bucket
    # 
    # + bucketName - The name of the bucket.
    # + delimiter - A delimiter is a character you use to group keys.
    # + encodingType - The encoding method to be applied on the response.
    # + maxKeys - The maximum number of keys to include in the response.
    # + prefix - The prefix of the objects to be listed. If unspecified, all objects are listed.
    # + startAfter - Object key from where to begin listing.
    # + fetchOwner - Set to true, to retrieve the owner information in the response. By default the API does not return
    #                the Owner information in the response.
    # + continuationToken - When the response to this API call is truncated (that is, the IsTruncated response element 
    #                       value is true), the response also includes the NextContinuationToken element. 
    #                       To list the next set of objects, you can use the NextContinuationToken element in the next 
    #                       request as the continuation-token.
    # 
    # + return - If success, returns S3Object[] object, else returns error
    remote function listObjects(string bucketName, string? delimiter = (), string? encodingType = (), int? maxKeys = (),
                                string? prefix = (), string? startAfter = (), boolean? fetchOwner = (), 
                                string? continuationToken = ()) returns @tainted S3Object[]|error {
        map<string> queryParamsMap = {};  
        string requestURI = string `/${bucketName}/`;
        string queryParamsStr = "?list-type=2";
        queryParamsMap["list-type"] = "2";

        string queryParams = populateOptionalParameters(queryParamsMap, delimiter = delimiter, encodingType = 
            encodingType, maxKeys = maxKeys, prefix = prefix, startAfter = startAfter, fetchOwner = fetchOwner,
            continuationToken = continuationToken);
        queryParamsStr = string `${queryParamsStr}${queryParams}`;
        map<string> requestHeaders = {
            [HOST]: self.amazonHost,
            [X_AMZ_CONTENT_SHA256]: UNSIGNED_PAYLOAD
        };
        check generateSignature(self.accessKeyId, self.secretAccessKey, self.region, GET, requestURI, UNSIGNED_PAYLOAD,
            requestHeaders, queryParams = queryParamsMap);

        requestURI = string `${requestURI}${queryParamsStr}`;
        var httpResponse = self.amazonS3->get(requestURI, requestHeaders);
        if (httpResponse is http:Response) {
            xml xmlPayload = check httpResponse.getXmlPayload();
            if (httpResponse.statusCode == http:STATUS_OK) {
                return getS3ObjectsList(xmlPayload);
            }
            return error(xmlPayload.toString());
        }
        return error(API_INVOCATION_ERROR_MSG + "listing objects from bucket " + bucketName);
    }

     # Retrieves objects from Amazon S3.
     #
     # + bucketName - The name of the bucket.
     # + objectName - The name of the object.
     # + objectRetrievalHeaders - Optional headers for the get object function.
     #
     # + return - If success, returns S3ObjectContent object, else returns error
    remote function getObject(string bucketName, string objectName,
                                ObjectRetrievalHeaders? objectRetrievalHeaders = ()) returns @tainted S3Object|error {
        string requestURI = string `/${bucketName}/${objectName}`;

         map<string> requestHeaders = {
            [HOST]: self.amazonHost,
            [X_AMZ_CONTENT_SHA256]: UNSIGNED_PAYLOAD
        };
        
        // Add optional headers.
        populateGetObjectHeaders(requestHeaders, objectRetrievalHeaders);
        
        check generateSignature(self.accessKeyId, self.secretAccessKey, self.region, GET, requestURI, UNSIGNED_PAYLOAD,
            requestHeaders);

        var httpResponse = self.amazonS3->get(requestURI, requestHeaders);
        if (httpResponse is http:Response) {
            if (httpResponse.statusCode == http:STATUS_OK) {
                byte[]|error binaryPayload = httpResponse.getBinaryPayload();
                if (binaryPayload is error) {
                    return error(BINARY_CONTENT_EXTRACTION_ERROR_MSG, binaryPayload);
                } else {
                    return getS3Object(binaryPayload);
                }
            } else {
                xml xmlPayload = check httpResponse.getXmlPayload();
                return error(xmlPayload.toString());
            }
        }
        return error(API_INVOCATION_ERROR_MSG + "extracting object " + objectName + " from bucket " + bucketName);
    }

    # Create an object.
    #
    # + bucketName - The name of the bucket.
    # + objectName - The name of the object.
    # + payload - The file content that needed to be added to the bucket.
    # + cannedACL - The access control list of the new object.
    # + objectCreationHeaders - Optional headers for the create object function.
    #
    # + return - If failed returns error
    remote function createObject(string bucketName, string objectName, string|xml|json|byte[] payload,
                                    CannedACL? cannedACL = (), ObjectCreationHeaders? objectCreationHeaders = ())
                                    returns @tainted error? {
        map<string> requestHeaders = {};
        http:Request request = new;
        string requestURI = string `/${bucketName}/${objectName}`;

        requestHeaders[HOST] = self.amazonHost;
        requestHeaders[X_AMZ_CONTENT_SHA256] = UNSIGNED_PAYLOAD;

        if (payload is byte[]) {
            request.setBinaryPayload(payload, contentType = "application/octet-stream");
        } else {
            request.setPayload(payload);
        }

        // Add optional headers.
        populateCreateObjectHeaders(requestHeaders, objectCreationHeaders);

        check generateSignature(self.accessKeyId, self.secretAccessKey, self.region, PUT, requestURI, UNSIGNED_PAYLOAD,
            requestHeaders, request);

        var httpResponse = self.amazonS3->put(requestURI, request);
        if (httpResponse is http:Response) {
            return handleHttpResponse(httpResponse);
        }
        return error (API_INVOCATION_ERROR_MSG + "creating object.");
    }

    # Delete an object.
    # 
    # + bucketName - The name of the bucket.
    # + objectName - The name of the object
    # + versionId - The specific version of the object to delete, if versioning is enabled.
    # 
    # + return - If failed returns error
    remote function deleteObject(string bucketName, string objectName, string? versionId = ()) 
                                    returns @tainted error? {
        map<string> requestHeaders = {};
        map<string> queryParamsMap = {};
        http:Request request = new;
        string queryParamsStr = "";
        string requestURI = string `/${bucketName}/${objectName}`;

        // Append query parameter(versionId).
        if (versionId is string) {
            queryParamsStr = string `${queryParamsStr}?versionId=${versionId}`;
            queryParamsMap["versionId"] = versionId;
        } 
        
        requestHeaders[HOST] = self.amazonHost;
        requestHeaders[X_AMZ_CONTENT_SHA256] = UNSIGNED_PAYLOAD;
        check generateSignature(self.accessKeyId, self.secretAccessKey, self.region, DELETE, requestURI,
            UNSIGNED_PAYLOAD, requestHeaders, request, queryParams = queryParamsMap);

        requestURI = string `${requestURI}${queryParamsStr}`;
        var httpResponse = self.amazonS3->delete(requestURI, request);
        if (httpResponse is http:Response) {
            return handleHttpResponse(httpResponse);
        }
        return error(API_INVOCATION_ERROR_MSG + "deleting object " + objectName + " from bucket " + bucketName);
    }     

    # Delete a bucket.
    # 
    # + bucketName - The name of the bucket.
    # 
    # + return - If failed returns error
    remote function deleteBucket(string bucketName) returns @tainted error? {
        map<string> requestHeaders = {};
        http:Request request = new;
        string requestURI = string `/${bucketName}`;

        requestHeaders[HOST] = self.amazonHost;
        requestHeaders[X_AMZ_CONTENT_SHA256] = UNSIGNED_PAYLOAD;
        check generateSignature(self.accessKeyId, self.secretAccessKey, self.region, DELETE, requestURI,
            UNSIGNED_PAYLOAD, requestHeaders, request);

        var httpResponse = self.amazonS3->delete(requestURI, request);
        if (httpResponse is http:Response) {
            return handleHttpResponse(httpResponse);
        }
        return error(API_INVOCATION_ERROR_MSG + "deleting bucket " + bucketName);
    }
}

# Verify the existence of credentials.
#
# + accessKeyId - The access key is of the Amazon S3 account.
# + secretAccessKey - The secret access key of the Amazon S3 account.
# 
# + return - Returns an error object if accessKeyId or secretAccessKey not exists.
isolated function verifyCredentials(string accessKeyId, string secretAccessKey) returns error? {
    if ((accessKeyId == "") || (secretAccessKey == "")) {
        return error(EMPTY_VALUES_FOR_CREDENTIALS_ERROR_MSG);
    }
}

# AmazonS3 Connector configurations can be setup here.
# + accessKeyId - The access key is of the Amazon S3 account.
# + secretAccessKey - The secret access key of the Amazon S3 account.
# + region - The AWS Region. If you don't specify an AWS region, Client uses US East (N. Virginia) as 
#            default region.
# + clientConfig - HTTP client config
# + secureSocketConfig - Secure Socket config
public type ClientConfiguration record {
    string accessKeyId;
    string secretAccessKey;
    string region = DEFAULT_REGION;
    http:ClientConfiguration clientConfig = {http1Settings: {chunking: http:CHUNKING_NEVER}};
    http:ClientSecureSocket secureSocketConfig?;
};
