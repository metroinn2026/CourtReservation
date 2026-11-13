/* CourtReservation admin MFA (TOTP).
 * Opt-in enrollment. For accounts with a verified factor, sign-in requires AAL2.
 * No tokens, QR secrets or OTP codes are persisted by this module.
 */
(function(root){
  'use strict';
  const state={client:null,onVerified:null,onCancel:null,restore:false,pendingId:null,verifiedFactors:[],busy:false};
  const el=id=>document.getElementById(id);
  function show(id,visible){el(id)?.classList.toggle('hidden',!visible);}
  function message(id,content){const node=el(id);if(node)node.textContent=String(content||'');}
  function sixDigits(raw){return /^\d{6}$/.test(String(raw||'').trim());}
  function setLoginVisible(visible){
    show('loginBox',!visible);
    show('adminMfaLoginBox',visible);
    if(visible)el('adminMfaLoginCode')?.focus();
    else {if(el('adminMfaLoginCode'))el('adminMfaLoginCode').value='';message('adminMfaLoginMsg','');}
  }
  async function getVerifiedFactors(){
    const {data,error}=await state.client.auth.mfa.listFactors();
    if(error)throw error;
    return (data?.totp||[]).filter(f=>!f.status||f.status==='verified');
  }
  async function gate(restored=false){
    if(!state.client)throw Error('尚未初始化驗證器服務');
    const {data,error}=await state.client.auth.mfa.getAuthenticatorAssuranceLevel();
    if(error)throw error;
    if(!data || !['aal1','aal2'].includes(data.currentLevel)
       || !['aal1','aal2'].includes(data.nextLevel)){
      throw Error('無法確認登入驗證等級');
    }
    if(data.currentLevel==='aal1'&&data.nextLevel==='aal2'){
      const factors=await getVerifiedFactors();
      if(!factors.length)throw Error('此帳號已啟用 MFA，但無法取得驗證器資料；請洽系統管理員');
      state.verifiedFactors=factors;
      state.restore=!!restored;
      const selector=el('adminMfaFactorSelect');
      if(selector){
        selector.replaceChildren();
        factors.forEach((factor,i)=>{
          const option=document.createElement('option');
          option.value=factor.id;
          option.textContent=factor.friendly_name||('驗證器 '+(i+1));
          selector.appendChild(option);
        });
      }
      show('adminMfaFactorRow',factors.length>1);
      message('adminMfaLoginMsg','');
      setLoginVisible(true);
      return true;
    }
    setLoginVisible(false);
    return false;
  }
  async function challengeAndVerify(factorId,code){
    if(!factorId||!sixDigits(code))throw Error('請輸入驗證器提供的 6 位數驗證碼');
    const challenge=await state.client.auth.mfa.challenge({factorId});
    if(challenge.error)throw challenge.error;
    const verified=await state.client.auth.mfa.verify({
      factorId,challengeId:challenge.data.id,code:String(code).trim()
    });
    if(verified.error)throw verified.error;
    const aal=await state.client.auth.mfa.getAuthenticatorAssuranceLevel();
    if(aal.error||aal.data?.currentLevel!=='aal2')throw Error('驗證未完成，請重試');
  }
  async function verifyLogin(){
    if(state.busy)return;
    state.busy=true;
    const btn=el('adminMfaVerifyBtn');if(btn)btn.disabled=true;
    try{
      const factor=el('adminMfaFactorSelect')?.value||state.verifiedFactors[0]?.id;
      await challengeAndVerify(factor,el('adminMfaLoginCode')?.value);
      const restored=state.restore;
      setLoginVisible(false);
      await state.onVerified(restored);
    }catch(e){
      message('adminMfaLoginMsg',e?.message||'驗證失敗，請重新輸入');
      if(el('adminMfaLoginCode'))el('adminMfaLoginCode').value='';
    }finally{if(btn)btn.disabled=false;state.busy=false;}
  }
  async function cancelLogin(){
    setLoginVisible(false);
    await state.onCancel?.();
  }
  let settingsDialog=null;
  function closeSettings(){
    const pending=state.pendingId;
    state.pendingId=null;
    if(settingsDialog){settingsDialog.remove();settingsDialog=null;}
    // Unverified enrollment is not an active factor. Clean it up on cancel.
    if(pending)void state.client.auth.mfa.unenroll({factorId:pending}).catch(()=>{});
  }
  async function openSettings(){
    if(settingsDialog)return;
    if(!state.client)throw Error('驗證器服務尚未初始化');
    settingsDialog=document.createElement('div');
    settingsDialog.className='modal admin-mfa-modal';
    settingsDialog.setAttribute('role','dialog');
    settingsDialog.setAttribute('aria-modal','true');
    settingsDialog.setAttribute('aria-label','管理員帳號安全');
    settingsDialog.innerHTML=`
      <div class="modal-card" style="max-width:440px;width:min(94vw,440px);">
        <h3>帳號安全</h3>
        <p class="small" style="line-height:1.8">使用手機驗證器保護個人管理員帳號。設定完成後，往後登入需輸入一次性驗證碼。</p>
        <p id="adminMfaSettingStatus" class="small" aria-live="polite">正在查詢驗證器...</p>
        <div id="adminMfaEnrollment" class="hidden">
          <img id="adminMfaQr" alt="驗證器設定 QR Code" width="180" height="180" style="display:block;margin:12px auto;max-width:100%;"/>
          <details class="small"><summary>無法掃描？顯示手動設定密鑰</summary><code id="adminMfaSecret" style="display:block;overflow-wrap:anywhere;padding:8px 0;user-select:all"></code></details>
          <label for="adminMfaEnrollCode" style="display:block;font-size:13px;margin:12px 0 5px">驗證器顯示的 6 位數驗證碼</label>
          <input id="adminMfaEnrollCode" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="6 位數驗證碼" style="width:100%;padding:10px;border:1px solid #d1d5db;border-radius:9px"/>
          <button id="adminMfaEnrollVerifyBtn" type="button" class="btn btn-primary" style="margin-top:10px;width:100%">驗證並啟用</button>
        </div>
        <p id="adminMfaSettingMsg" class="small" role="status" aria-live="polite"></p>
        <div class="modal-actions">
          <button id="adminMfaSettingCloseBtn" class="btn btn-gray" type="button">關閉</button>
          <button id="adminMfaAddBtn" class="btn btn-primary" type="button">設定驗證器</button>
        </div>
      </div>`;
    document.body.appendChild(settingsDialog);
    settingsDialog.querySelector('#adminMfaSettingCloseBtn').onclick=closeSettings;
    settingsDialog.querySelector('#adminMfaAddBtn').onclick=startEnrollment;
    settingsDialog.querySelector('#adminMfaEnrollVerifyBtn').onclick=verifyEnrollment;
    settingsDialog.querySelector('#adminMfaEnrollCode').onkeydown=e=>{if(e.key==='Enter')void verifyEnrollment();};
    settingsDialog.querySelector('#adminMfaSettingCloseBtn').focus();
    try{
      const factors=await getVerifiedFactors();
      if(!settingsDialog)return;
      const count=factors.length;
      message('adminMfaSettingStatus',count
        ? '已啟用雙重驗證（'+count+' 組驗證器）。建議保留備援驗證器，以防手機遺失。'
        : '目前尚未設定雙重驗證。');
      const btn=el('adminMfaAddBtn');
      if(btn){btn.textContent=count?'新增備援驗證器':'設定驗證器';btn.disabled=count>=10;}
    }catch(e){message('adminMfaSettingStatus','讀取驗證器狀態失敗：'+(e.message||String(e)));el('adminMfaAddBtn').disabled=true;}
  }
  async function startEnrollment(){
    if(!settingsDialog||state.busy)return;
    const btn=el('adminMfaAddBtn');btn.disabled=true;state.busy=true;
    try{
      const {data,error}=await state.client.auth.mfa.enroll({factorType:'totp'});
      if(error)throw error;
      if(!settingsDialog){await state.client.auth.mfa.unenroll({factorId:data.id}).catch(()=>{});return;}
      state.pendingId=data.id;
      const svg=String(data.totp?.qr_code||'');
      if(!svg.includes('<svg'))throw Error('驗證器 QR Code 無法讀取');
      el('adminMfaQr').src='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(svg);
      el('adminMfaSecret').textContent=data.totp?.secret||'';
      show('adminMfaEnrollment',true);
      show('adminMfaAddBtn',false);
      message('adminMfaSettingMsg','請掃描 QR Code，並輸入驗證器顯示的 6 位數密碼。');
      el('adminMfaEnrollCode').focus();
    }catch(e){
      message('adminMfaSettingMsg','無法設定驗證器：'+(e.message||String(e)));
      btn.disabled=false;
    }finally{state.busy=false;}
  }
  async function verifyEnrollment(){
    if(!state.pendingId||state.busy)return;
    state.busy=true;
    const btn=el('adminMfaEnrollVerifyBtn');if(btn)btn.disabled=true;
    try{
      await challengeAndVerify(state.pendingId,el('adminMfaEnrollCode')?.value);
      state.pendingId=null;
      if(settingsDialog){
        show('adminMfaEnrollment',false);
        if(el('adminMfaQr'))el('adminMfaQr').removeAttribute('src');
        message('adminMfaSecret','');
        message('adminMfaSettingStatus','已啟用雙重驗證。下次登入必須完成驗證器驗證。');
        message('adminMfaSettingMsg','設定完成。請妥善保管驗證器，建議新增一組備援驗證器。');
        const add=el('adminMfaAddBtn');
        if(add){add.textContent='新增備援驗證器';add.disabled=false;show('adminMfaAddBtn',true);}
      }
    }catch(e){message('adminMfaSettingMsg','驗證失敗：'+(e.message||String(e)));}
    finally{if(btn)btn.disabled=false;state.busy=false;}
  }
  function init(client,onVerified,onCancel){
    state.client=client;state.onVerified=onVerified;state.onCancel=onCancel;
    const loginBtn=el('adminMfaVerifyBtn');
    if(loginBtn)loginBtn.onclick=verifyLogin;
    const cancelBtn=el('adminMfaCancelBtn');
    if(cancelBtn)cancelBtn.onclick=cancelLogin;
    const otp=el('adminMfaLoginCode');
    if(otp)otp.onkeydown=e=>{if(e.key==='Enter')void verifyLogin();};
    const settingsBtn=el('adminMfaSettingsBtn');
    if(settingsBtn)settingsBtn.onclick=()=>{void openSettings();};
  }
  root.CourtAdminMfa=Object.freeze({init,gate,openSettings,sixDigits});
})(window);
