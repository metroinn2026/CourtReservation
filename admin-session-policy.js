/* CourtReservation admin session policy: side-effect-free rules shared by browser and Node tests. */
(function(root,factory){
  const api=factory();
  if(typeof module==='object' && module.exports) module.exports=api;
  if(root) root.CourtAdminSessionPolicy=api;
})(typeof window!=='undefined'?window:null,function(){
  'use strict';
  const IDLE_MS=20*60*1000;
  const VERIFY_MS=5*60*1000;
  const MAX_SESSION_MS=8*60*60*1000;
  function validTimestamp(value){
    const n=Number(value);
    return Number.isFinite(n)&&n>0?n:0;
  }
  function elapsed(now,then){return Math.max(0,Number(now)-validTimestamp(then));}
  function expired(lastActivity,now=Date.now(),limit=IDLE_MS){
    const ts=validTimestamp(lastActivity);
    return !ts || !Number.isFinite(now) || now<ts || now-ts>=limit;
  }
  function needsVerification(lastVerified,now=Date.now(),limit=VERIFY_MS){
    return expired(lastVerified,now,limit);
  }
  function mustReauthenticate(startedAt,now=Date.now()){
    return expired(startedAt,now,MAX_SESSION_MS);
  }
  return Object.freeze({IDLE_MS,VERIFY_MS,MAX_SESSION_MS,validTimestamp,elapsed,expired,needsVerification,mustReauthenticate});
});
