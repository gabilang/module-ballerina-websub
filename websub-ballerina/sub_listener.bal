// Copyright (c) 2021, WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
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

import ballerina/http;
import ballerina/log;

# Represents a Subscriber Service listener endpoint.
public class Listener {
    private http:Listener httpListener;
    private http:ListenerConfiguration listenerConfig;
    private SubscriberServiceConfiguration? serviceConfig;
    private string? callbackUrl;
    private int port;
    private HttpService? httpService;

    # Invoked during the initialization of a `websub:Listener`. Either an `http:Listener` or a port number must be
    # provided to initialize the listener.
    #
    # + listenTo - An `http:Listener` or a port number to listen for the service
    # + config - `websub:ListenerConfiguration` to be provided to underlying HTTP Listener
    public isolated function init(int|http:Listener listenTo, *ListenerConfiguration config) returns error? {
        if (listenTo is int) {
            self.httpListener = check new(listenTo, config);
        } else {
            self.httpListener = listenTo;
        }
        self.listenerConfig = self.httpListener.getConfig();
        self.port = self.httpListener.getPort();
        self.httpService = ();
        self.serviceConfig = ();
        self.callbackUrl = ();
    }

    # Attaches the provided Service to the Listener.
    #
    # + subscriberService - The `websub:SubscriberService` object to attach
    # + name - The path of the Service to be hosted
    # + return - An `error`, if an error occurred during the service attaching process
    public isolated function attach(SubscriberService subscriberService, string[]|string? name = ()) returns error? {
        if (self.listenerConfig.secureSocket is ()) {
            log:printWarn("HTTPS is recommended but using HTTP");
        }

        var configuration = retrieveSubscriberServiceAnnotations(subscriberService);
        if (configuration is SubscriberServiceConfiguration) {
            self.serviceConfig = configuration;
            string[]|string servicePath = retrieveServicePath(name);
            self.callbackUrl = retrieveCallbackUrl(
                        configuration?.callback, configuration.appendServiceUrl, 
                        servicePath, self.port, self.listenerConfig);
            if (isLoggingGeneratedCallback(configuration?.callback, name)) {
                log:printInfo("Autogenerated callback ", URL = self.callbackUrl);
            }
            self.httpService = check new(subscriberService, configuration?.secret);
            check self.httpListener.attach(<HttpService> self.httpService, servicePath);
        } else {
            return error ListenerError("Could not find the required service-configurations");
        }
    }

    # Setup the provided Service with given configurations and attaches it to the listener
    #
    # + subscriberService - The `websub:SubscriberService` object to attach
    # + configuration - `SubscriberServiceConfiguration` which should be incorporated into the provided Service 
    # + name - The path of the Service to be hosted
    # + return - An `error`, if an error occurred during the service attaching process
    public isolated function attachWithConfig(SubscriberService subscriberService, SubscriberServiceConfiguration configuration, string[]|string? name = ()) returns error? {
        if (self.listenerConfig.secureSocket is ()) {
            log:printWarn("HTTPS is recommended but using HTTP");
        }
        
        self.serviceConfig = configuration;
        string[]|string servicePath = retrieveServicePath(name);
        self.callbackUrl = retrieveCallbackUrl(
                        configuration?.callback, configuration.appendServiceUrl, 
                        servicePath, self.port, self.listenerConfig);
        
        if (isLoggingGeneratedCallback(configuration?.callback, name)) {
            log:printInfo("Autogenerated callback ", URL = self.callbackUrl);
        }   

        self.httpService = check new(subscriberService, configuration?.secret);
        check self.httpListener.attach(<HttpService> self.httpService, servicePath);        
            
    }
    
    # Detaches the provided Service from the Listener.
    #
    # + s - The service to be detached
    # + return - An `error`, if an error occurred during the service detaching process
    public isolated function detach(SubscriberService s) returns error? {
        check self.httpListener.detach(<HttpService> self.httpService);
    }

    # Starts the attached Service.
    #
    # + return - An `error`, if an error occurred during the listener starting process
    public isolated function 'start() returns error? {
        check self.httpListener.'start();

        var serviceConfig = self.serviceConfig;
        var callback = self.callbackUrl;
        if (serviceConfig is SubscriberServiceConfiguration) {
            var result = initiateSubscription(serviceConfig, <string>callback);
            if (result is error) {
                string errorMsg = string`Subscription initiation failed due to [${result.message()}]`;
                return error SubscriptionInitiationFailedError(errorMsg);
            }
        }
    }

    # Gracefully stops the hub listener. Already accepted requests will be served before the connection closure.
    #
    # + return - An `error`, if an error occurred during the listener stopping process
    public isolated function gracefulStop() returns error? {
        return self.httpListener.gracefulStop();
    }

    # Stops the service listener immediately. It is not implemented yet.
    #
    # + return - An `error`, if an error occurred during the listener stopping process
    public isolated function immediateStop() returns error? {
        return self.httpListener.immediateStop();
    }
}

# Retrieves the `websub:SubscriberServiceConfig` annotation values
# 
# + return - {@code websub:SubscriberServiceConfiguration} if present or `nil` if absent
isolated function retrieveSubscriberServiceAnnotations(SubscriberService serviceType) returns SubscriberServiceConfiguration? {
    typedesc<any> serviceTypedesc = typeof serviceType;
    return serviceTypedesc.@SubscriberServiceConfig;
}

# Retrieves the service-path for the HTTP Service
# 
# + name - user provided service path
# + return - {@code string} or {@code string[]} value for service path
isolated function retrieveServicePath(string[]|string? name) returns string[]|string {
    if (name is ()) {
        return generateUniqueUrlSegment();
    } else if (name is string) {
        return name;
    } else {
        if ((<string[]>name).length() == 0) {
            return generateUniqueUrlSegment();
        } else {
            return <string[]>name;
        }
    }
}

# Generates a unique URL segment for the subscriber service
# 
# + return - {@code string} containing the generated unique URL path segment
isolated function generateUniqueUrlSegment() returns string {
    var generatedString = generateRandomString(10);
    if (generatedString is string) {
        return generatedString;
    } else {
        return COMMON_SERVICE_PATH;
    }
}

isolated function retrieveCallbackUrl(string? providedCallback, boolean appendServicePath, 
                                      string[]|string servicePath, int port, 
                                      http:ListenerConfiguration config) returns string {
    if (providedCallback is string) {
        if (appendServicePath) {
            string completeSevicePath = retrieveCompleteServicePath(servicePath);
            return string`${providedCallback}${completeSevicePath}`;
        } else {
            return providedCallback;
        }
    } else {
        return generateCallbackUrl(servicePath, port, config);
    }
}

# Dynamically generates the call-back URL for subscriber-service
# 
# + servicePath - service path on which the service will be hosted
# + config - {@code http:ListenerConfiguration} in use
# + return - {@code string} contaning the generated URL
isolated function generateCallbackUrl(string[]|string servicePath, 
                                     int port, http:ListenerConfiguration config) returns string {
    string host = config.host;
    string protocol = config.secureSocket is () ? "http" : "https";        
    string completeSevicePath = retrieveCompleteServicePath(servicePath);
    return string`${protocol}://${host}:${port.toString()}${completeSevicePath}`;
}

# Retrieved the complete service path
# 
# + servicePath - user provided service path which could be {@code string} or {@code string[]}
# + return - concatenated complete service path
isolated function retrieveCompleteServicePath(string[]|string servicePath) returns string {
    string concatenatedServicePath = "";
    if (servicePath is string) {
        concatenatedServicePath += "/" + <string>servicePath;
    } else {
        foreach var pathSegment in <string[]>servicePath {
            concatenatedServicePath += "/" + pathSegment;
        }
    }
    return concatenatedServicePath;
}

# Identifies whether or not to log callback URL
# 
# + providedCallback - user provided callback URL
# + servicePath - user provided service path
# + return - 'true' if the user provided callback is nil and service path is nil or 'false' otherwise
isolated function isLoggingGeneratedCallback(string? providedCallback, string[]|string? servicePath) returns boolean {
    return providedCallback is () && (servicePath is () || (servicePath is string[] && (<string[]>servicePath).length() == 0));
}

# Initiate the subscription to the `topic` in the mentioned `hub`
#
# + serviceConfig - {@code SubscriberServiceConfiguration} subscriber-service
#                   related configurations
# + return - An `error`, if an error occurred during the subscription-initiation
isolated function initiateSubscription(SubscriberServiceConfiguration serviceConfig, string callbackUrl) returns error? {
    string|[string, string]? target = serviceConfig?.target;
        
    string hubUrl;
    string topicUrl;
        
    if (target is string) {
        var discoveryConfig = serviceConfig?.discoveryConfig;
        http:ClientConfiguration? discoveryHttpConfig = discoveryConfig?.httpConfig ?: ();
        string?|string[] expectedMediaTypes = discoveryConfig?.accept ?: ();
        string?|string[] expectedLanguageTypes = discoveryConfig?.acceptLanguage ?: ();

        DiscoveryService discoveryClient = check new (target, discoveryHttpConfig);
        var discoveryDetails = discoveryClient->discoverResourceUrls(expectedMediaTypes, expectedLanguageTypes);
        if (discoveryDetails is [string, string]) {
            [hubUrl, topicUrl] = <[string, string]> discoveryDetails;
        } else {
            return error ResourceDiscoveryFailedError(discoveryDetails.message());
        }
    } else if (target is [string, string]) {
        [hubUrl, topicUrl] = <[string, string]> target;
    } else {
        log:printWarn("Subscription not initiated as subscriber target-URL is not provided");
        return;
    }

    SubscriptionClient subscriberClientEp = check getSubscriberClient(hubUrl, serviceConfig?.httpConfig);
    SubscriptionChangeRequest request = retrieveSubscriptionRequest(topicUrl, callbackUrl, serviceConfig);
    var response = subscriberClientEp->subscribe(request);
    if (response is SubscriptionChangeResponse) {
        string subscriptionSuccessMsg = string`Subscription Request successfully sent to Hub[${response.hub}], for Topic[${response.topic}], with Callback [${callbackUrl}]`;
        log:printInfo(string`${subscriptionSuccessMsg}. Awaiting intent verification.`);
    } else {
        return response;
    }
}

# Initialize a subscriber-client with provided configurations
# 
# + hubUrl - URL of the hub to which subscriber is going to subscribe
# + config - Nillable {@code http:ClientConfiguration} for underlying {@code http:Client}
# + return - {@code SubscriptionClient} or error
isolated function getSubscriberClient(string hubUrl, http:ClientConfiguration? config) returns SubscriptionClient|error {
    if (config is http:ClientConfiguration) {
        return check new SubscriptionClient(hubUrl, config); 
    } else {
        return check new SubscriptionClient(hubUrl);
    }
}
