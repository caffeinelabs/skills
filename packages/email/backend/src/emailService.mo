module {
  public type EmailService = actor {
    send_email : (SendEmailArgs) -> async Response;
    broadcast_email : (BroadcastEmailArgs) -> async Response;
    send_calendar_event : (SendCalendarEventArgs) -> async Response;
  };

  public type SendEmailArgs = {
    from_username : Text;
    to : [Text];
    cc : [Text];
    bcc : [Text];
    subject : Text;
    html_body : Text;
  };

  public type BroadcastEmailArgs = {
    sub_type : BroadcastEmailType;
    from_username : Text;
    recipients : [BroadcastEmailRecipient];
    subject : Text;
    html_body : Text;
  };

  public type BroadcastEmailType = {
    #Service;
    #Marketing : MarketingEmail;
    #Verification;
  };

  public type MarketingEmail = {
    topic_id : Nat32;
  };

  public type BroadcastEmailRecipient = {
    email : Text;
    substitutions : ?[(Text, Text)];
  };

  public type SendCalendarEventArgs = {
    uid : Text;
    sequence : Nat32;
    method : CalendarEventMethod;
    summary : Text;
    description : Text;
    location : Text;
    start_time : Nat64;
    end_time : Nat64;
    organizer : Mailbox;
    from_username : Text;
    attendees : [Attendee];
  };

  public type CalendarEventMethod = {
    #Request;
    #Publish;
    #Cancel;
  };

  public type Mailbox = {
    email : Text;
    name : ?Text;
  };

  public type Attendee = {
    who : Mailbox;
    role : CalendarEventRole;
  };

  public type CalendarEventRole = {
    #Chair;
    #Required;
    #Optional;
    #NotParticipating;
  };

  public type Response = {
    cycles_charged : Nat;
    result : Result;
  };

  public type Result = {
    #Ok : Success;
    #Err : Error;
  };

  public type Success = {};

  public type Error = {
    #UnknownError : Text;
    #InvalidArgs : Text;
    #TooFewCyclesAttached : TooFewCyclesAttached;
    #FailedToCallService : Text;
    #FailedToDeserializeServiceResponse : Text;
  };

  public type TooFewCyclesAttached = {
    required : Nat;
    attached : Nat;
  };
};
