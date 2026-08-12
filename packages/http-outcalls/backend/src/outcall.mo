import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Runtime "mo:core/Runtime";
import Int "mo:core/Int";
import Time "mo:core/Time";
import Array "mo:core/Array";
import IC "mo:ic/Types";
import Call "mo:ic/Call";

module {
  public func transform(input : TransformationInput) : TransformationOutput {
    let response = input.response;
    {
      response with headers = [];
    };
  };

  public type TransformationInput = {
    context : Blob;
    response : IC.HttpRequestResult;
  };
  public type TransformationOutput = IC.HttpRequestResult;
  public type Transform = query TransformationInput -> async TransformationOutput;
  public type Header = {
    name : Text;
    value : Text;
  };
  public type Method = {
    #get;
    #head;
    #post;
    #put;
    #delete;
    #patch;
  };
  public type Request = {
    url : Text;
    method : Method;
    headers : [Header];
    body : ?Blob;
    maxResponseBytes : Nat64;
    transform : Transform;
  };
  public type Response = IC.HttpRequestResult;
  public let defaultMaxResponseBytes : Nat64 = 1_000_000;

  public func httpRequest(request : Request) : async Response {
    let headers = request.headers.concat([{
      name = "User-Agent";
      value = "caffeine.ai";
    }]);
    let maxResponseBytes = if (request.maxResponseBytes <= defaultMaxResponseBytes) {
      request.maxResponseBytes;
    } else {
      defaultMaxResponseBytes;
    };
    let args : IC.HttpRequestArgs = {
      url = request.url;
      max_response_bytes = ?(maxResponseBytes);
      headers;
      body = request.body;
      method = request.method;
      transform = ?{
        function = request.transform;
        context = Blob.fromArray([]);
      };
      is_replicated = ?false;
    };
    await Call.httpRequest(args);
  };

  public func httpGetRequest(url : Text, extraHeaders : [Header], transform : Transform) : async Text {
    let httpResponse = await httpRequest({
      url;
      method = #get;
      headers = extraHeaders;
      body = null;
      maxResponseBytes = defaultMaxResponseBytes;
      transform;
    });
    httpResponse.body.decodeUtf8() ?? Runtime.trap("empty HTTP response");
  };

  public func httpPostRequest(url : Text, extraHeaders : [Header], body : Text, transform : Transform) : async Text {
    let headers = extraHeaders.concat([
      { name = "Idempotency-Key"; value = "Time-" # Time.now().toText() },
    ]);
    let httpResponse = await httpRequest({
      url;
      method = #post;
      headers;
      body = ?(body.encodeUtf8());
      maxResponseBytes = defaultMaxResponseBytes;
      transform;
    });
    httpResponse.body.decodeUtf8() ?? Runtime.trap("empty HTTP response");
  };
};
