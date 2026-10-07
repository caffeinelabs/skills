import Text "mo:core/Text";
import Blob "mo:core/Blob";

module {
  public type HeaderField = (Text, Text);

  public type Request = {
    method : Text;
    url : Text;
    headers : [HeaderField];
    body : Blob;
    certificate_version : ?Nat16;
  };

  public type StreamingCallbackToken = {
    key : Text;
    content_encoding : Text;
    index : Nat;
    sha256 : ?Blob;
  };

  public type StreamingCallbackHttpResponse = {
    body : Blob;
    token : ?StreamingCallbackToken;
  };

  public type StreamingStrategy = {
    #Callback : {
      callback : shared query StreamingCallbackToken -> async StreamingCallbackHttpResponse;
      token : StreamingCallbackToken;
    };
  };

  public type Response = {
    status_code : Nat16;
    headers : [HeaderField];
    body : Blob;
    streaming_strategy : ?StreamingStrategy;
    upgrade : ?Bool;
  };

  public func path(url : Text) : Text {
    switch (url.split(#char '?').next()) {
      case (?p) p;
      case null url;
    };
  };

  public func header(req : Request, name : Text) : ?Text {
    let target = name.toLower();
    for ((key, value) in req.headers.values()) {
      if (key.toLower() == target) {
        return ?value;
      };
    };
    null;
  };

  public func text(status : Nat16, body : Text) : Response {
    {
      status_code = status;
      headers = [("content-type", "text/plain; charset=utf-8")];
      body = body.encodeUtf8();
      streaming_strategy = null;
      upgrade = null;
    };
  };

  public func upgrade() : Response {
    {
      status_code = 200;
      headers = [];
      body = "".encodeUtf8();
      streaming_strategy = null;
      upgrade = ?true;
    };
  };

  public func notFound() : Response {
    text(404, "not found");
  };

  public func methodNotAllowed() : Response {
    text(405, "method not allowed");
  };

  public func bodyText(req : Request) : ?Text {
    req.body.decodeUtf8();
  };
};
