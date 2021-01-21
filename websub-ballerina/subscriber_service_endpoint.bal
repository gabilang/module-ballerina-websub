// Copyright (c) 2018 WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
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

import ballerina/encoding;
import ballerina/http;
import ballerina/log;
import ballerina/jballerina.java;

//////////////////////////////////////////
/// WebSub Subscriber Service Endpoint ///
//////////////////////////////////////////
# Represents the WebSubSubscriber Service Listener.
#
# + config - The configurations for the `websub:Listener`
public class Listener {

    public SubscriberListenerConfiguration? config = ();

    private http:Listener? serviceEndpoint = ();

    # Creates a new `websub:Listener`.
    #
    # + port - The port number of the remote service
    # + config - The configurations related to the `websub:Listener`
    public isolated function init(int port, SubscriberListenerConfiguration? config = ()) returns error? {
        self.config = config;
        http:ListenerConfiguration? serviceConfig = ();
        if (config is SubscriberListenerConfiguration) {
            http:ListenerConfiguration httpServiceConfig = {
                host: config.host,
                secureSocket: config.httpServiceSecureSocket
            };
            serviceConfig = httpServiceConfig;
        }
        http:Listener httpEndpoint = check new(port, serviceConfig);
        self.serviceEndpoint = httpEndpoint;

        externInitWebSubSubscriberServiceEndpoint(self);
    }

    # Binds a service to the `websub:Listener`.
    # ```ballerina
    # error? result = websubListener.attach(helloService);
    # ```
    #
    # + s - Type descriptor of the service
    # + name - Name of the service
    # + return - `()` or else an `error` upon failure to register the listener
    public isolated function attach(SubscriberService s, string[]|string? name = ()) returns error? {
        // TODO: handle data and return error on error
        externRegisterWebSubSubscriberService(self, s, name);
    }

    # Stops consuming messages and detaches the service from the `websub:Listener`.
    # ```ballerina
    # error? result = websubListener.detach(helloService);
    # ```
    #
    # + s - Type descriptor of the service
    # + return - `()` or else an `error` upon failure to detach the service
    public isolated function detach(SubscriberService s) returns error? {
    }

    # Starts the `websub:Listener`.
    # ```ballerina
    # error? result = websubListener.'start();
    # ```
    #
    # + return - `()` or else an `error` upon failure to start the listener
    public function 'start() returns @tainted error? {
        check externStartWebSubSubscriberServiceEndpoint(self);
        // TODO: handle data and return error on error
        check self.sendSubscriptionRequests();
    }

    isolated function processWebSubNotification(http:Request request, SubscriberService serviceType) returns @tainted error? {
        return processWebSubNotification(request, serviceType);
    }

    # Stops the `websub:Listener` gracefully.
    # ```ballerina
    # error? result = websubListener.gracefulStop();
    # ```
    #
    # + return - `()` or else an `error` upon failure to stop the listener
    public isolated function gracefulStop() returns error? {
        http:Listener? sListener = self.serviceEndpoint;
        if (sListener is http:Listener) {
            return sListener.gracefulStop();
        }
        return ();
    }

    # Stops the `websub:Listener` forcefully.
    # ```ballerina
    # error? result = websubListener.immediateStop();
    # ```
    #
    # + return - () or else an `error` upon failure to stop the listener
    public isolated function immediateStop() returns error? {
    }

    # Sends subscription requests to the specified/discovered hubs if specified to subscribe on startup.
    function sendSubscriptionRequests() returns @tainted error? {
        map<any>[] subscriptionDetailsArray = externRetrieveSubscriptionParameters(self);

        foreach map<any> subscriptionDetails in subscriptionDetailsArray {
            if (subscriptionDetails.keys().length() == 0) {
                continue;
            }

            boolean subscribeOnStartUp = <boolean> subscriptionDetails[ANNOT_FIELD_SUBSCRIBE_ON_STARTUP];

            if (subscribeOnStartUp) {
                string? resourceUrl = ();
                string? hub = ();
                string topic;

                if (!subscriptionDetails.hasKey(ANNOT_FIELD_TARGET)) {
                    log:printError(
                        "Subscription request not sent since hub and topic or resource URL are not specified");
                    return;
                }
                any target = subscriptionDetails.get(ANNOT_FIELD_TARGET);

                if (target is string) {
                    resourceUrl = target;
                } else {
                    [hub, topic] = <[string, string]> target;
                }

                http:ClientConfiguration? hubClientConfig =
                                        <http:ClientConfiguration?> subscriptionDetails[ANNOT_FIELD_HUB_CLIENT_CONFIG];

                if (resourceUrl is string) {
                    http:ClientConfiguration? publisherClientConfig =
                                <http:ClientConfiguration?> subscriptionDetails[ANNOT_FIELD_PUBLISHER_CLIENT_CONFIG];
                    string?|string[] expectedMediaType = <string?|string[]> subscriptionDetails[ANNOT_FIELD_ACCEPT];
                    string?|string[] expectedLanguageType = <string?|string[]> subscriptionDetails[ANNOT_FIELD_ACCEPT_LANGUAGE];
                    var discoveredDetails = retrieveHubAndTopicUrl(resourceUrl, publisherClientConfig, expectedMediaType, expectedLanguageType);
                    if (discoveredDetails is [string, string]) {
                        var [retHub, retTopic] = discoveredDetails;
                        var hubDecodeResponse = encoding:decodeUriComponent(retHub, "UTF-8");
                        if (hubDecodeResponse is string) {
                            retHub = hubDecodeResponse;
                        } else {
                            panic <encoding:DecodingError> hubDecodeResponse;
                        }
                        var topicDecodeResponse = encoding:decodeUriComponent(retTopic, "UTF-8");
                        if (topicDecodeResponse is string) {
                            retTopic = topicDecodeResponse;
                        } else {
                            panic <encoding:DecodingError> topicDecodeResponse;
                        }
                        hub = retHub;
                        [string, string] hubAndTopic = [retHub, retTopic];
                        subscriptionDetails[ANNOT_FIELD_TARGET] = hubAndTopic;
                        string webSubServiceName = <string>subscriptionDetails["webSubServiceName"];
                        self.setTopic(webSubServiceName, retTopic);
                    } else {
                        log:printError("Error sending out subscription request on start up: " +
                                        discoveredDetails.message());
                        continue;
                    }
                }
                check invokeClientConnectorForSubscription(<string> hub, hubClientConfig, <@untainted> subscriptionDetails);
            }
        }
    }

    # Sets the topic to which this service is subscribing, for auto intent verification.
    #
    # + webSubServiceName - The name of the service for which subscription happened for a topic
    # + topic - The topic the subscription happened for
    isolated function setTopic(string webSubServiceName, string topic) {
        externSetTopic(self, webSubServiceName, topic);
    }
}

///////////////////////////////////////////////////////////////////
//////////////////// WebSub Subscriber Natives ////////////////////
///////////////////////////////////////////////////////////////////

isolated function externInitWebSubSubscriberServiceEndpoint(Listener subscriberListener) = @java:Method {
    name: "initWebSubSubscriberServiceEndpoint",
    'class: "org.ballerinalang.net.websub.nativeimpl.SubscriberNativeOperationHandler"
} external;

isolated function externRegisterWebSubSubscriberService(Listener subscriberListener, SubscriberService serviceType, string[]|string? name) = @java:Method {
    name: "registerWebSubSubscriberService",
    'class: "org.ballerinalang.net.websub.nativeimpl.SubscriberNativeOperationHandler"
} external;

isolated function externStartWebSubSubscriberServiceEndpoint(Listener subscriberListener) returns error? = @java:Method {
    name: "startWebSubSubscriberServiceEndpoint",
    'class: "org.ballerinalang.net.websub.nativeimpl.SubscriberNativeOperationHandler"
} external;

isolated function externSetTopic(Listener subscriberListener, string webSubServiceName, string topic) = @java:Method {
    name: "setTopic",
    'class: "org.ballerinalang.net.websub.nativeimpl.SubscriberNativeOperationHandler"
} external;

isolated function externRetrieveSubscriptionParameters(Listener subscriberListener) returns map<any>[] = @java:Method {
    name: "retrieveSubscriptionParameters",
    'class: "org.ballerinalang.net.websub.nativeimpl.SubscriberNativeOperationHandler"
} external;


# Represents the configuration for the WebSub Subscriber Service Listener.
#
# + host - The host name/IP of the WebSub Subscriber Service Listener
# + httpServiceSecureSocket - The SSL configurations for the WebSub Subscriber Service Listener
# + extensionConfig - The extension configuration to introduce custom subscriber services (webhooks)
public type SubscriberListenerConfiguration record {|
    string host = "";
    http:ListenerSecureSocket? httpServiceSecureSocket = ();
    ExtensionConfig? extensionConfig = ();
|};

# The extension configuration to introduce custom subscriber services.
#
# + topicIdentifier - The identifier based on which dispatching should happen for custom subscriber
# + topicHeader - The header to consider if required with dispatching for custom services
# + headerResourceMap - The mapping between header value and resource details
# + payloadKeyResourceMap - The mapping between value for a particular JSON payload key and resource details
# + headerAndPayloadKeyResourceMap - The mapping between values for the header and a particular JSON payload key and resource details
public type ExtensionConfig record {|
    TopicIdentifier topicIdentifier = TOPIC_ID_HEADER;

    // TODO: make `Link` the default header and special case `Link` to extract the topic (rel="self").
    // <link href="<HUB_URL>"; rel="hub", href="<TOPIC_URL>"; rel="self"/>
    string? topicHeader = ();

    // e.g.,
    //  headerResourceMap = {
    //    "watch" : ("onWatch", WatchEvent),
    //    "create" : ("onCreate", CreateEvent)
    //  };
    map<[string, typedesc<record {}>]>? headerResourceMap = ();

    // e.g.,
    //  payloadKeyResourceMap = {
    //    "eventType" : {
    //        "branch.created":  ("onBranchCreate", BranchCreatedEvent),
    //        "branch.deleted":  ("onBranchDelete", BranchDeletedEvent)
    //    }
    //  };
    map<map<[string, typedesc<record {}>]>>? payloadKeyResourceMap = ();

    // e.g.,
    //  headerAndPayloadKeyResourceMap = {
    //    "issue_comment" : { <--- value for header
    //        "action" : { <--- payload key
    //            "created" : ("onIssueCommentCreated", IssueCommentEvent), <--- "created" - value for key "action"
    //            "edited" : ("onIssueCommentEdited", IssueCommentEvent),
    //            "deleted" : ("onIssueCommentDeleted", IssueCommentEvent)
    //        }
    //    }
    //  };
    map<map<map<[string, typedesc<record {}>]>>>? headerAndPayloadKeyResourceMap = ();
|};

# Discovers the hub and topic URLs defined by a resource URL.
#
# + resourceUrl - The resource URL advertising the hub and topic URLs
# + publisherClientConfig - The configuration for the publisher client
# + expectedMediaType - The expected media type for the subscriber client
# + expectedLanguageType - The expected language type for the subscriber client
# + return - A `(hub, topic)` as a `(string, string)` if successful or else an `error` if not
function retrieveHubAndTopicUrl(string resourceUrl, http:ClientConfiguration? publisherClientConfig, string?|string[] expectedMediaType, string?|string[] expectedLanguageType)
        returns @tainted [string, string]|error {
    http:Client resourceEP = check new http:Client(resourceUrl, publisherClientConfig);
    http:Request request = new;
    if (expectedMediaType is string) {
        request.addHeader(ACCEPT_HEADER, expectedMediaType);
    }
    
    if (expectedMediaType is string[]) {
        string acceptMeadiaTypesString = expectedMediaType[0];
        foreach string mediaType in expectedMediaType {
            acceptMeadiaTypesString = acceptMeadiaTypesString.concat(", ", mediaType);
        }
        request.addHeader(ACCEPT_HEADER, acceptMeadiaTypesString);
    }
    
    if (expectedLanguageType is string) {
        request.addHeader(ACCEPT_LANGUAGE_HEADER, expectedLanguageType);
    }
    
    if (expectedLanguageType is string[]) {
        string acceptLanguageTypesString = expectedLanguageType[0];
        foreach string languageType in expectedLanguageType {
            acceptLanguageTypesString = acceptLanguageTypesString.concat(", ", languageType);
        }
        request.addHeader(ACCEPT_LANGUAGE_HEADER, acceptLanguageTypesString);
    }
    
    var discoveryResponse = resourceEP->get("", request);
    if (discoveryResponse is http:Response) {
        var topicAndHubs = extractTopicAndHubUrls(discoveryResponse);
        if (topicAndHubs is [string, string[]]) {
            string topic = "";
            string[] hubs = [];
            [topic, hubs] = topicAndHubs;
            return [hubs[0], topic]; // guaranteed by `extractTopicAndHubUrls` for hubs to have length > 0
        } else {
            return topicAndHubs;
        }
    } else {
        return error WebSubError("Error occurred with WebSub discovery for Resource URL [" +resourceUrl + "]: " +
                            (<error>discoveryResponse).message());
    }
}

# Invokes the `WebSubSubscriberConnector`'s remote functions for the subscription.
#
# + hub - The hub to which the subscription request is to be sent
# + hubClientConfig - The configuration for the hub client
# + subscriptionDetails - The subscription details as a `map`
function invokeClientConnectorForSubscription(string hub, http:ClientConfiguration? hubClientConfig,
                                              map<any> subscriptionDetails) returns error? {
    SubscriptionClient websubHubClientEP = check new (hub, hubClientConfig);
    [string, string][_, topic] = <[string, string]> subscriptionDetails[ANNOT_FIELD_TARGET];
    string callback = <string> subscriptionDetails[ANNOT_FIELD_CALLBACK];

    SubscriptionChangeRequest subscriptionChangeRequest = { topic: topic, callback: callback };

    if (subscriptionDetails.hasKey(ANNOT_FIELD_LEASE_SECONDS)) {
        subscriptionChangeRequest.leaseSeconds = <int> subscriptionDetails[ANNOT_FIELD_LEASE_SECONDS];
    }

    if (subscriptionDetails.hasKey(ANNOT_FIELD_SECRET)) {
         subscriptionChangeRequest.secret =  <string> subscriptionDetails[ANNOT_FIELD_SECRET];
    }

    var subscriptionResponse = websubHubClientEP->subscribe(subscriptionChangeRequest);
    if (subscriptionResponse is SubscriptionChangeResponse) {
        string subscriptionSuccessMsg = "Subscription Request successfully sent to Hub[" + subscriptionResponse.hub +
                                "], for Topic[" + subscriptionResponse.topic + "], with Callback [" + callback + "]";

        boolean expectIntentVerification = <boolean> subscriptionDetails[ANNOT_FIELD_EXPECT_INTENT_VERIFICATION];
        if (expectIntentVerification) {
            log:print(subscriptionSuccessMsg + ". Awaiting intent verification.");
            return;
        }
        log:print(subscriptionSuccessMsg);
    } else {
        log:printError("Subscription Request failed at Hub[" + hub + "], for Topic[" + topic + "]: " +
                       subscriptionResponse.message());
    }
}
