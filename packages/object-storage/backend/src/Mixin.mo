import Nat "mo:core/Nat";
import Array "mo:core/Array";
import Text "mo:core/Text";
import Storage "Storage";
import Prim "mo:prim";
import Runtime "mo:core/Runtime";

mixin () {
  type ExternalBlob = Storage.ExternalBlob;

  transient let _immutableObjectStorageState : Storage.State = Storage.new();

  type _ImmutableObjectStorageRefillInformation = {
    proposed_top_up_amount : ?Nat;
  };

  type _ImmutableObjectStorageRefillResult = {
    success : ?Bool;
    topped_up_amount : ?Nat;
  };

  type _ImmutableObjectStorageCreateCertificateResult = {
    method : Text;
    blob_hash : Text;
  };

  public shared ({ caller }) func _immutableObjectStorageRefillCashier(refillInformation : ?_ImmutableObjectStorageRefillInformation) : async _ImmutableObjectStorageRefillResult {
    let cashier = await Storage.getCashierPrincipal();
    if (cashier != caller) {
      Runtime.trap("Unauthorized access");
    };
    await Storage.refillCashier(_immutableObjectStorageState, cashier, refillInformation);
  };

  public shared ({ caller }) func _immutableObjectStorageUpdateGatewayPrincipals() : async () {
    await Storage.updateGatewayPrincipals(_immutableObjectStorageState);
  };

  public query ({ caller }) func _immutableObjectStorageBlobsAreLive(hashes : [Blob]) : async [Bool] {
    hashes.map(func(hash){
      Prim.isStorageBlobLive(hash)
    })
  };

  public query ({ caller }) func _immutableObjectStorageBlobsToDelete() : async [Blob] {
    if (not Storage.isAuthorized(_immutableObjectStorageState, caller)) {
      Runtime.trap("Unauthorized access");
    };
    let deadBlobs = Prim.getDeadBlobs();
    switch (deadBlobs) {
      case (null) {
        [];
      };
      case (?deadBlobs) {
        deadBlobs.sliceToArray(0, 10000);
      };
    };
  };

  public shared ({ caller }) func _immutableObjectStorageConfirmBlobDeletion(blobs : [Blob]) : async () {
    if (not Storage.isAuthorized(_immutableObjectStorageState, caller)) {
      Runtime.trap("Unauthorized access");
    };
    Prim.pruneConfirmedDeadBlobs(blobs);
    // Trigger GC forcefully.
    type GC = actor {
      __motoko_gc_trigger : () -> async ();
    };
    let myGC = actor (debug_show (Prim.getSelfPrincipal<system>())) : GC;
    await myGC.__motoko_gc_trigger();
  };

  public shared ({ caller }) func _immutableObjectStorageCreateCertificate(blobHash : Text) : async _ImmutableObjectStorageCreateCertificateResult {
    {
      method = "upload";
      blob_hash = blobHash;
    };
  };
};
