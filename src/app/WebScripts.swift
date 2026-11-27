import Foundation
import WebKit

final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

enum WebScripts {
    static func compatPolyfillScript() -> WKUserScript {
        let js = #"""
        (function(){
        'use strict';
        try{
          if(typeof Promise==='function'&&typeof Promise.withResolvers!=='function'){
            Object.defineProperty(Promise,'withResolvers',{configurable:true,writable:true,value:function withResolvers(){
              var resolve,reject;
              var promise=new this(function(res,rej){resolve=res;reject=rej;});
              return{promise:promise,resolve:resolve,reject:reject};
            }});
          }
          if(typeof Promise==='function'&&typeof Promise.try!=='function'){
            Object.defineProperty(Promise,'try',{configurable:true,writable:true,value:function promiseTry(fn){
              var args=Array.prototype.slice.call(arguments,1);
              return new this(function(resolve){resolve(fn.apply(undefined,args));});
            }});
          }
          if(typeof URL==='function'&&typeof URL.parse!=='function'){
            Object.defineProperty(URL,'parse',{configurable:true,writable:true,value:function parse(url,base){
              try{return(arguments.length>1&&base!==undefined)?new URL(url,base):new URL(url);}catch(_){return null;}
            }});
          }
          if(typeof URL==='function'&&typeof URL.canParse!=='function'){
            Object.defineProperty(URL,'canParse',{configurable:true,writable:true,value:function canParse(url,base){
              try{if(arguments.length>1&&base!==undefined){new URL(url,base);}else{new URL(url);}return true;}catch(_){return false;}
            }});
          }
          if(typeof Object.groupBy!=='function'){
            Object.defineProperty(Object,'groupBy',{configurable:true,writable:true,value:function groupBy(items,cb){
              var out=Object.create(null),idx=0;
              for(var item of items){var k=cb(item,idx++);if(Object.prototype.hasOwnProperty.call(out,k)){out[k].push(item);}else{out[k]=[item];}}
              return out;
            }});
          }
          if(typeof Map==='function'&&typeof Map.groupBy!=='function'){
            Object.defineProperty(Map,'groupBy',{configurable:true,writable:true,value:function groupBy(items,cb){
              var out=new Map(),idx=0;
              for(var item of items){var k=cb(item,idx++),arr=out.get(k);if(arr){arr.push(item);}else{out.set(k,[item]);}}
              return out;
            }});
          }
          if(typeof AbortSignal==='function'&&typeof AbortSignal.any!=='function'){
            Object.defineProperty(AbortSignal,'any',{configurable:true,writable:true,value:function any(signals){
              var ctrl=new AbortController(),list=Array.from(signals||[]);
              for(var i=0;i<list.length;i++){if(list[i]&&list[i].aborted){ctrl.abort(list[i].reason);return ctrl.signal;}}
              var onAbort=function(ev){
                ctrl.abort(ev&&ev.target?ev.target.reason:undefined);
                for(var j=0;j<list.length;j++){if(list[j])list[j].removeEventListener('abort',onAbort);}
              };
              for(var k=0;k<list.length;k++){if(list[k])list[k].addEventListener('abort',onAbort,{once:true});}
              return ctrl.signal;
            }});
          }
        }catch(_){}
        })();
        """#
        return WKUserScript(
            source: js,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
    }

    static func inputContrastFixScript() -> WKUserScript {
        let js = #"""
        (function(){
        'use strict';
        if(window.__jwContrastFixInstalled)return;
        window.__jwContrastFixInstalled=true;
        var SKIP_TYPES={hidden:1,checkbox:1,radio:1,button:1,submit:1,reset:1,image:1,file:1,range:1,color:1};
        var patched=new WeakMap();
        function isTextInput(el){
          if(!el||el.nodeType!==1)return false;
          var tag=el.tagName;
          if(tag==='TEXTAREA')return true;
          if(tag==='INPUT'){var t=(el.getAttribute('type')||'text').toLowerCase();return !SKIP_TYPES[t];}
          return false;
        }
        function parseColor(str){
          if(!str||typeof str!=='string')return null;
          str=str.trim().toLowerCase();
          if(str==='transparent')return{r:0,g:0,b:0,a:0};
          var m=str.match(/^rgba?\(([^)]+)\)$/);
          if(m){
            var body=m[1].trim();
            var alpha=1;
            var slash=body.split('/');
            if(slash.length===2){
              var aStr=slash[1].trim();
              alpha=aStr.endsWith('%')?parseFloat(aStr)/100:parseFloat(aStr);
              body=slash[0].trim();
            }
            var parts=body.indexOf(',')!==-1?body.split(','):body.split(/\s+/);
            if(parts.length<3)return null;
            var r=parseFloat(parts[0]),g=parseFloat(parts[1]),b=parseFloat(parts[2]);
            if(parts.length>=4&&slash.length===1){
              var a4=parts[3].trim();
              alpha=a4.endsWith('%')?parseFloat(a4)/100:parseFloat(a4);
            }
            if(isNaN(r)||isNaN(g)||isNaN(b)||isNaN(alpha))return null;
            return{r:Math.max(0,Math.min(255,r)),g:Math.max(0,Math.min(255,g)),b:Math.max(0,Math.min(255,b)),a:Math.max(0,Math.min(1,alpha))};
          }
          var srgb=str.match(/^color\(\s*srgb\s+([\d.e+-]+)\s+([\d.e+-]+)\s+([\d.e+-]+)(?:\s*\/\s*([\d.e+%-]+))?\s*\)$/);
          if(srgb){
            var a=1;
            if(srgb[4]!==undefined){a=srgb[4].endsWith('%')?parseFloat(srgb[4])/100:parseFloat(srgb[4]);}
            return{r:Math.max(0,Math.min(255,parseFloat(srgb[1])*255)),g:Math.max(0,Math.min(255,parseFloat(srgb[2])*255)),b:Math.max(0,Math.min(255,parseFloat(srgb[3])*255)),a:isNaN(a)?1:Math.max(0,Math.min(1,a))};
          }
          return null;
        }
        function compositeOver(fg,bg){
          var a=fg.a;
          return{r:fg.r*a+bg.r*(1-a),g:fg.g*a+bg.g*(1-a),b:fg.b*a+bg.b*(1-a),a:1};
        }
        function baseCanvasColor(){
          try{
            var isDark=window.matchMedia&&window.matchMedia('(prefers-color-scheme: dark)').matches;
            if(isDark&&document.documentElement){
              var cs=(getComputedStyle(document.documentElement).colorScheme||'').toLowerCase();
              if(cs.indexOf('dark')!==-1&&cs!=='only light')return{r:18,g:18,b:18,a:1};
            }
          }catch(_){}
          return{r:255,g:255,b:255,a:1};
        }
        function effectiveBackground(el){
          var layers=[],node=el,depth=0;
          while(node&&node.nodeType===1&&depth<40){
            var bg=parseColor(getComputedStyle(node).backgroundColor);
            if(bg&&bg.a>0.01){
              layers.push(bg);
              if(bg.a>=0.99)break;
            }
            var next=node.parentElement;
            if(!next&&node.getRootNode){var rn=node.getRootNode();if(rn&&rn.host)next=rn.host;}
            node=next;
            depth++;
          }
          var cur=(layers.length>0&&layers[layers.length-1].a>=0.99)?layers.pop():baseCanvasColor();
          for(var i=layers.length-1;i>=0;i--){cur=compositeOver(layers[i],cur);}
          return cur;
        }
        function luminance(c){
          function lin(v){v/=255;return v<=0.03928?v/12.92:Math.pow((v+0.055)/1.055,2.4);}
          return 0.2126*lin(c.r)+0.7152*lin(c.g)+0.0722*lin(c.b);
        }
        function contrastRatio(c1,c2){
          var l1=luminance(c1),l2=luminance(c2);
          return(Math.max(l1,l2)+0.05)/(Math.min(l1,l2)+0.05);
        }
        function restoreOriginal(el){
          var orig=patched.get(el);
          if(!orig)return;
          if(orig.color)el.style.setProperty('color',orig.color,orig.colorPrio);
          else el.style.removeProperty('color');
          if(orig.fill)el.style.setProperty('-webkit-text-fill-color',orig.fill,orig.fillPrio);
          else el.style.removeProperty('-webkit-text-fill-color');
          if(orig.caret)el.style.setProperty('caret-color',orig.caret,orig.caretPrio);
          else el.style.removeProperty('caret-color');
        }
        function saveOriginal(el){
          if(patched.has(el))return;
          patched.set(el,{
            color:el.style.getPropertyValue('color'),
            colorPrio:el.style.getPropertyPriority('color'),
            fill:el.style.getPropertyValue('-webkit-text-fill-color'),
            fillPrio:el.style.getPropertyPriority('-webkit-text-fill-color'),
            caret:el.style.getPropertyValue('caret-color'),
            caretPrio:el.style.getPropertyPriority('caret-color')
          });
        }
        function checkAndFix(el){
          try{
            if(!isTextInput(el))return;
            var wasPatched=patched.has(el);
            if(wasPatched)restoreOriginal(el);
            var cs=getComputedStyle(el);
            if(!cs||cs.display==='none'||cs.visibility==='hidden'){if(wasPatched)patched.delete(el);return;}
            var op=parseFloat(cs.opacity);
            if(!isNaN(op)&&op<0.05){if(wasPatched)patched.delete(el);return;}
            var fs=parseFloat(cs.fontSize);
            if(!isNaN(fs)&&fs<1){if(wasPatched)patched.delete(el);return;}
            var rect=el.getBoundingClientRect();
            if(rect.width<=2||rect.height<=2){if(wasPatched)patched.delete(el);return;}
            var rawColor=parseColor(cs.color);
            var rawFill=parseColor(cs.getPropertyValue('-webkit-text-fill-color'));
            if((rawColor&&rawColor.a<0.05)||(rawFill&&rawFill.a<0.05)){if(wasPatched)patched.delete(el);return;}
            var selfBg=parseColor(cs.backgroundColor);
            if((!selfBg||selfBg.a<0.05)&&cs.backgroundImage&&cs.backgroundImage!=='none'){if(wasPatched)patched.delete(el);return;}
            var fg=rawFill||rawColor;
            if(!fg){if(wasPatched)patched.delete(el);return;}
            var bg=effectiveBackground(el);
            var effFg=(fg.a<0.99)?compositeOver(fg,bg):fg;
            var ratio=contrastRatio(effFg,bg);
            if(ratio<2.6){
              saveOriginal(el);
              var target=luminance(bg)>0.35?'#111827':'#f8fafc';
              el.style.setProperty('color',target,'important');
              el.style.setProperty('-webkit-text-fill-color',target,'important');
              el.style.setProperty('caret-color',target,'important');
            }else if(wasPatched){
              patched.delete(el);
            }
          }catch(_){}
        }
        function eventTarget(ev){
          if(ev&&typeof ev.composedPath==='function'){var p=ev.composedPath();if(p&&p.length)return p[0];}
          return ev?ev.target:null;
        }
        document.addEventListener('focusin',function(ev){
          var t=eventTarget(ev);
          if(!isTextInput(t))return;
          checkAndFix(t);
          requestAnimationFrame(function(){checkAndFix(t);});
          setTimeout(function(){checkAndFix(t);},80);
        },true);
        document.addEventListener('input',function(ev){checkAndFix(eventTarget(ev));},true);
        document.addEventListener('change',function(ev){checkAndFix(eventTarget(ev));},true);
        document.addEventListener('blur',function(ev){
          var t=eventTarget(ev);
          if(isTextInput(t)&&(patched.has(t)||(t.value&&t.value.length>0))){checkAndFix(t);}
        },true);
        window.__jwRecheckInputs=function(){
          try{
            if(document.activeElement)checkAndFix(document.activeElement);
            var list=document.querySelectorAll('input,textarea');
            for(var i=0;i<list.length;i++){
              var el=list[i];
              if(el===document.activeElement||patched.has(el)||(el.value&&el.value.length>0))checkAndFix(el);
            }
          }catch(_){}
        };
        try{
          var mq=window.matchMedia('(prefers-color-scheme: dark)');
          if(mq&&mq.addEventListener)mq.addEventListener('change',function(){setTimeout(window.__jwRecheckInputs,50);});
        }catch(_){}
        })();
        """#
        return WKUserScript(
            source: js,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false,
            in: .defaultClient
        )
    }

    static func diagnosticJSErrorScript() -> WKUserScript {
        let js = #"""
        (function(){
        'use strict';
        if(window.__jwDiagInstalled)return;
        window.__jwDiagInstalled=true;
        var count=0;
        function post(kind,msg){
          if(count>=25)return;
          count++;
          try{
            if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.jwDiag){
              window.webkit.messageHandlers.jwDiag.postMessage({k:kind,m:String(msg||'')});
            }
          }catch(_){}
        }
        window.addEventListener('error',function(ev){
          var m=(ev&&ev.message?ev.message:'error')+(ev&&ev.filename?' @'+ev.filename+':'+(ev.lineno||0):'');
          post('error',m);
        });
        window.addEventListener('unhandledrejection',function(ev){
          var r=ev?ev.reason:null;
          var m=r?(r.message||String(r)):'unhandledrejection';
          post('promise',m);
        });
        })();
        """#
        return WKUserScript(
            source: js,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
    }

    /// Universal 3-in-1 conversation & unread message detector:
    /// 1) Polyfills `window.Notification` + `ServiceWorkerRegistration.prototype.showNotification`
    /// 2) Monitors `document.title` unread counters `(1)` / `[新消息]`
    /// 3) Detects newly appearing unread dots in conversation lists & settled streaming replies (`Muse` / `agy` / `Hermes`)
    static func conversationMonitorScript() -> WKUserScript {
        let js = #"""
        (function(){
        'use strict';
        if(window.__jwNotifyInstalled)return;
        window.__jwNotifyInstalled=true;

        var hostState={appActive:true,tabSelected:true};
        var bootIgnoreUntil=Date.now()+4800;
        var lastHref=location.href;
        var lastComposerText='';
        var lastComposerInputAt=0;
        var lastUserSentAt=0;
        var lastWatchedMutationAt=0;
        var lastBaselineTail='';
        var lastNotifiedSnippet='';
        var lastNotifiedAt=0;
        var lastStreamPingAt=0;
        var pendingReply=false;
        var streamStartedAt=0;
        var settleTimer=null;
        var dotScanTimer=null;
        var knownUnreadTitles=new Set();
        var lastTitleCount=0;

        function postNative(payload){
          try{
            if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.jwNotify){
              window.webkit.messageHandlers.jwNotify.postMessage(payload);
            }
          }catch(_){}
        }

        function isUserWatching(){
          return !!(hostState.appActive && hostState.tabSelected && document.visibilityState!=='hidden');
        }

        function normText(s){
          return String(s||'').replace(/\s+/g,' ').trim();
        }

        function isTrivialStatusOrTime(t){
          if(!t||t.length<2)return true;
          if(/^(\d+\s*(s|sec|m|min|h|hr|d|秒|分钟|小时|天)(\s*ago|前)?|just now|刚刚|剛剛|\d{1,2}:\d{2}(\s*[ap]m)?)$/i.test(t))return true;
          if(/^(thinking|analyzing|generating|loading|working|running|searching|思考中|正在输入|加载中)[.…·\s]*$/i.test(t))return true;
          return false;
        }

        /* 1. Polyfill standard Web Notification API -> Native iOS Banner */
        try{
          if(typeof window.Notification==='undefined'){
            var JWNotification=function(title,options){
              var opts=options||{};
              this.title=String(title||'');
              this.body=String(opts.body||'');
              this.tag=String(opts.tag||'');
              this.onclick=null;
              this.onclose=null;
              postNative({
                k:'web_api',
                sub:this.title,
                body:this.body||'收到一条新网页通知'
              });
            };
            JWNotification.permission='granted';
            JWNotification.requestPermission=function(cb){
              if(typeof cb==='function'){try{cb('granted');}catch(_){}}
              return Promise.resolve('granted');
            };
            JWNotification.prototype.close=function(){
              if(typeof this.onclose==='function'){try{this.onclose();}catch(_){}}
            };
            JWNotification.prototype.addEventListener=function(){};
            JWNotification.prototype.removeEventListener=function(){};
            window.Notification=JWNotification;
          }
          if(window.ServiceWorkerRegistration&&window.ServiceWorkerRegistration.prototype&&!window.ServiceWorkerRegistration.prototype.__jwPatched){
            window.ServiceWorkerRegistration.prototype.__jwPatched=true;
            window.ServiceWorkerRegistration.prototype.showNotification=function(title,options){
              var opts=options||{};
              postNative({k:'web_api',sub:String(title||''),body:String(opts.body||'收到一条新网页通知')});
              return Promise.resolve();
            };
          }
        }catch(_){}

        /* 2. Extract latest meaningful reply snippet from conversation DOM */
        function isInsideIgnoredChrome(el){
          var cur=el,d=0;
          while(cur&&cur.nodeType===1&&d<16){
            var tag=cur.tagName;
            if(tag==='NAV'||tag==='ASIDE'||tag==='HEADER'||tag==='FOOTER'||tag==='SCRIPT'||tag==='STYLE'||tag==='SVG'||tag==='TEXTAREA'||tag==='INPUT'||tag==='BUTTON'){
              return true;
            }
            if(cur.isContentEditable)return true;
            var role=(cur.getAttribute('role')||'').toLowerCase();
            if(role==='navigation'||role==='textbox'||role==='combobox'||role==='Dialog')return true;
            cur=cur.parentElement;
            d++;
          }
          return false;
        }

        function captureLatestChatSnippet(){
          try{
            if(!document.body)return '';
            var selectors=[
              '[data-message-author-role="assistant"]',
              '[data-role="assistant"]',
              '[class*="assistant" i]',
              '[class*="agent-message" i]',
              '[class*="model-response" i]',
              '[class*="markdown" i]',
              '[class*="prose" i]',
              '[class*="message-content" i]',
              '[class*="chat-message" i]',
              'main article',
              'main p',
              '[role="main"] p',
              '[role="log"] div'
            ];
            var best='';
            for(var s=0;s<selectors.length;s++){
              var nodes=document.querySelectorAll(selectors[s]);
              if(!nodes||!nodes.length)continue;
              for(var i=nodes.length-1;i>=Math.max(0,nodes.length-6);i--){
                var el=nodes[i];
                if(isInsideIgnoredChrome(el))continue;
                var r=el.getBoundingClientRect();
                if(r.width<=0||r.height<=0)continue;
                var txt=normText(el.innerText||el.textContent||'');
                if(txt.length>=4&&!isTrivialStatusOrTime(txt)&&txt!==lastComposerText){
                  best=txt;
                  break;
                }
              }
              if(best)break;
            }
            if(!best){
              var root=document.querySelector('main,[role="main"],[role="log"]')||document.body;
              var blocks=root.querySelectorAll('p,li,div');
              for(var j=blocks.length-1;j>=Math.max(0,blocks.length-40);j--){
                var b=blocks[j];
                if(b.children&&b.children.length>4)continue;
                if(isInsideIgnoredChrome(b))continue;
                var t=normText(b.innerText||b.textContent||'');
                if(t.length>=6&&t.length<=600&&!isTrivialStatusOrTime(t)&&t!==lastComposerText){
                  best=t;
                  break;
                }
              }
            }
            if(best.length>120){
              best=best.slice(0,120)+'…';
            }
            return best;
          }catch(_){
            return '';
          }
        }

        /* 3. Unread blue/red dot scanner for conversation lists (e.g. Antigravity / Muse sidebar) */
        function extractRowTitleForDot(dotEl){
          var cur=dotEl.parentElement,d=0;
          while(cur&&cur.nodeType===1&&cur!==document.body&&d<6){
            var rect=cur.getBoundingClientRect();
            if(rect.height>=22&&rect.height<=92&&rect.width>=120){
              var raw=normText(cur.innerText||cur.textContent||'');
              raw=raw.replace(/\b\d+\s*(s|m|h|d|min|hr)\b$/i,'').trim();
              if(raw.length>=2&&raw.length<=95&&!isTrivialStatusOrTime(raw)){
                return raw;
              }
            }
            cur=cur.parentElement;
            d++;
          }
          return '';
        }

        function isColoredUnreadDot(el){
          if(!el||el.nodeType!==1)return false;
          var tag=el.tagName;
          if(tag!=='SPAN'&&tag!=='DIV'&&tag!=='I')return false;
          if(el.children&&el.children.length>0)return false;
          var txt=normText(el.textContent||'');
          if(txt.length>0)return false;
          var r=el.getBoundingClientRect();
          if(r.width<4.5||r.width>14.5||r.height<4.5||r.height>14.5)return false;
          if(Math.abs(r.width-r.height)>2.5)return false;
          var cs=getComputedStyle(el);
          if(cs.display==='none'||cs.visibility==='hidden'||parseFloat(cs.opacity)<0.35)return false;
          var br=parseFloat(cs.borderTopLeftRadius)||0;
          if(br<r.width*0.35)return false;
          var bg=cs.backgroundColor||'';
          var m=bg.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*[,/]\s*([\d.]+))?/);
          if(!m)return false;
          var rv=parseInt(m[1],10),gv=parseInt(m[2],10),bv=parseInt(m[3],10);
          var av=m[4]!==undefined?parseFloat(m[4]):1;
          if(av<0.45)return false;
          var spread=Math.max(rv,gv,bv)-Math.min(rv,gv,bv);
          return spread>=40;
        }

        function scanUnreadDots(allowEmit){
          try{
            if(!document.body)return;
            var currentSet=new Set();
            var explicit=document.querySelectorAll('[aria-label*="unread" i],[data-unread="true"],[title*="未读"]');
            for(var i=0;i<explicit.length;i++){
              var rt=extractRowTitleForDot(explicit[i])||normText(explicit[i].textContent||'');
              if(rt.length>=2&&rt.length<=95)currentSet.add(rt);
            }
            var navRoot=document.querySelector('nav,aside,[role="navigation"]');
            var scopeRoot=navRoot||document.body;
            var candidates=scopeRoot.querySelectorAll('a span,a div,li span,li div,[role="listitem"] span,[role="listitem"] div');
            var limit=Math.min(candidates.length,220);
            for(var j=0;j<limit;j++){
              var el=candidates[j];
              if(isColoredUnreadDot(el)){
                var rowTitle=extractRowTitleForDot(el);
                if(rowTitle)currentSet.add(rowTitle);
              }
            }
            if(allowEmit&&!isUserWatching()&&Date.now()>bootIgnoreUntil){
              currentSet.forEach(function(title){
                if(!knownUnreadTitles.has(title)){
                  if(Date.now()-lastNotifiedAt>=6000){
                    lastNotifiedAt=Date.now();
                    postNative({
                      k:'unread_dot',
                      sub:'新对话动态',
                      body:'「'+title+'」有新回复待查看'
                    });
                  }
                }
              });
            }
            knownUnreadTitles=currentSet;
          }catch(_){}
        }

        /* 4. Streaming / Generation busy check & reply settle detector */
        function isBusyGenerating(){
          if(streamStartedAt>0&&(Date.now()-streamStartedAt)>85000)return false;
          try{
            var btns=document.querySelectorAll('button,[role="button"]');
            for(var i=0;i<btns.length;i++){
              var b=btns[i];
              var label=((b.getAttribute('aria-label')||'')+' '+(b.getAttribute('title')||'')+' '+(b.getAttribute('data-testid')||'')).toLowerCase();
              if(label.indexOf('stop')!==-1||label.indexOf('停止')!==-1||label.indexOf('cancel generation')!==-1){
                var r=b.getBoundingClientRect();
                if(r.width>4&&r.height>4)return true;
              }
            }
          }catch(_){}
          return false;
        }

        function checkReplySettled(){
          settleTimer=null;
          if(!pendingReply)return;
          if(isUserWatching()){
            pendingReply=false;
            streamStartedAt=0;
            lastBaselineTail=captureLatestChatSnippet();
            return;
          }
          if(isBusyGenerating()){
            settleTimer=setTimeout(checkReplySettled,2000);
            return;
          }
          pendingReply=false;
          streamStartedAt=0;
          var snippet=captureLatestChatSnippet();
          if(!snippet||snippet===lastBaselineTail||snippet===lastNotifiedSnippet||snippet===lastComposerText){
            return;
          }
          if(Date.now()-lastNotifiedAt<6000)return;
          lastNotifiedAt=Date.now();
          lastNotifiedSnippet=snippet;
          lastBaselineTail=snippet;
          postNative({
            k:'reply_done',
            sub:'收到新回复',
            body:snippet
          });
        }

        function scheduleReplySettle(){
          if(Date.now()<bootIgnoreUntil)return;
          if(!pendingReply){
            pendingReply=true;
            streamStartedAt=Date.now();
          }
          if(!isUserWatching()&&(Date.now()-lastStreamPingAt)>12000){
            lastStreamPingAt=Date.now();
            postNative({k:'streaming'});
          }
          if(settleTimer)clearTimeout(settleTimer);
          settleTimer=setTimeout(checkReplySettled,3000);
        }

        /* 5. Title unread counter observer */
        function checkTitleBadge(){
          if(Date.now()<bootIgnoreUntil)return;
          var t=normText(document.title||'');
          var m=t.match(/^(?:\((\d+)\)|\[(\d+|新消息)\])\s*(.*)$/);
          if(!m){
            lastTitleCount=0;
            return;
          }
          var n=parseInt(m[1]||m[2]||'1',10);
          if(isNaN(n))n=1;
          if(n>lastTitleCount&&!isUserWatching()&&(Date.now()-lastNotifiedAt)>=6000){
            lastTitleCount=n;
            lastNotifiedAt=Date.now();
            postNative({
              k:'title_badge',
              sub:'有 '+n+' 条未读消息',
              body:m[3]||t
            });
          }else{
            lastTitleCount=n;
          }
        }

        function emitUserSentIfNeeded(){
          var now=Date.now();
          if(now-lastUserSentAt<2500)return;
          lastUserSentAt=now;
          postNative({k:'user_sent'});
        }

        /* 6. Composer input & send tracking */
        document.addEventListener('input',function(ev){
          var el=ev&&ev.target;
          if(!el)return;
          if(el.tagName==='TEXTAREA'||el.tagName==='INPUT'||el.isContentEditable){
            var v=normText(el.value||el.textContent||'');
            if(v.length>=2){
              lastComposerInputAt=Date.now();
              lastComposerText=v.length>120?(v.slice(0,120)+'…'):v;
            }
          }
        },true);

        document.addEventListener('keydown',function(ev){
          if(!ev||ev.key!=='Enter'||ev.shiftKey||ev.isComposing)return;
          var el=ev.target;
          if(el&&(el.tagName==='TEXTAREA'||el.isContentEditable||el.tagName==='INPUT')){
            emitUserSentIfNeeded();
          }
        },true);

        document.addEventListener('click',function(ev){
          var cur=ev&&ev.target,d=0;
          while(cur&&cur.nodeType===1&&d<5){
            if(cur.tagName==='BUTTON'||cur.getAttribute('role')==='button'){
              var tp=(cur.getAttribute('type')||'').toLowerCase();
              var lb=((cur.getAttribute('aria-label')||'')+' '+(cur.getAttribute('title')||'')+' '+(cur.textContent||'')).toLowerCase();
              if(tp==='submit'||/send|submit|发送|提交|ask|up-arrow/.test(lb)){
                emitUserSentIfNeeded();
              }else if((Date.now()-lastComposerInputAt)<45000&&!/cancel|close|attach|upload|voice|mic|menu|sidebar|copy|stop|取消|关闭|上传|菜单|复制|停止/.test(lb)){
                emitUserSentIfNeeded();
              }
              break;
            }
            cur=cur.parentElement;
            d++;
          }
        },true);

        /* 7. Host foreground/tab state hook */
        window.__jwUpdateHostState=function(st){
          var wasWatching=isUserWatching();
          if(st&&typeof st.appActive==='boolean')hostState.appActive=st.appActive;
          if(st&&typeof st.tabSelected==='boolean')hostState.tabSelected=st.tabSelected;
          var nowWatching=isUserWatching();
          if(wasWatching&&!nowWatching){
            lastBaselineTail=captureLatestChatSnippet();
            scanUnreadDots(false);
            var now=Date.now();
            if(isBusyGenerating()||((now-lastWatchedMutationAt)<6000&&(now-lastComposerInputAt)<180000)){
              scheduleReplySettle();
            }
          }else if(!wasWatching&&nowWatching){
            pendingReply=false;
            streamStartedAt=0;
            if(settleTimer){clearTimeout(settleTimer);settleTimer=null;}
            scanUnreadDots(false);
          }
        };

        document.addEventListener('visibilitychange',function(){
          if(document.visibilityState==='hidden'){
            if(!pendingReply)lastBaselineTail=captureLatestChatSnippet();
          }
        });

        /* 8. Start DOM MutationObserver after documentElement exists */
        function installObserver(){
          if(!document.documentElement)return;
          setTimeout(function(){
            lastBaselineTail=captureLatestChatSnippet();
            scanUnreadDots(false);
          },4600);

          var obs=new MutationObserver(function(mutations){
            if(location.href!==lastHref){
              lastHref=location.href;
              bootIgnoreUntil=Date.now()+4200;
              pendingReply=false;
              if(settleTimer){clearTimeout(settleTimer);settleTimer=null;}
              setTimeout(function(){
                lastBaselineTail=captureLatestChatSnippet();
                scanUnreadDots(false);
              },4300);
              return;
            }
            var now=Date.now();
            if(now<bootIgnoreUntil)return;

            /* Fast-path when user is actively watching this foreground tab:
             * zero DOM parent walks, zero textContent copies, zero dot scans! */
            if(isUserWatching()){
              for(var w=0;w<mutations.length;w++){
                var mw=mutations[w];
                if(mw.target&&mw.target.nodeName==='TITLE'){
                  checkTitleBadge();
                  continue;
                }
                if(mw.type==='characterData'||(mw.type==='childList'&&mw.addedNodes&&mw.addedNodes.length>0)){
                  lastWatchedMutationAt=now;
                  if((now-lastStreamPingAt)>15000&&((now-lastComposerInputAt)<180000||isBusyGenerating())){
                    lastStreamPingAt=now;
                    postNative({k:'streaming'});
                  }
                  break;
                }
              }
              return;
            }

            var hasMeaningfulText=false;
            var hasElementAdded=false;
            for(var i=0;i<mutations.length;i++){
              var m=mutations[i];
              if(m.target&&m.target.nodeName==='TITLE'){
                checkTitleBadge();
                continue;
              }
              if(m.type==='characterData'){
                var p=m.target?m.target.parentElement:null;
                if(p&&!isInsideIgnoredChrome(p)){
                  var t=normText(m.target.nodeValue||'');
                  if(t.length>=3&&!isTrivialStatusOrTime(t))hasMeaningfulText=true;
                }
              }else if(m.type==='childList'&&m.addedNodes&&m.addedNodes.length>0){
                hasElementAdded=true;
                if(!hasMeaningfulText&&m.target&&m.target.nodeType===1&&!isInsideIgnoredChrome(m.target)){
                  for(var k=0;k<m.addedNodes.length;k++){
                    var nd=m.addedNodes[k];
                    var nt=normText(nd.textContent||'');
                    if(nt.length>=4&&!isTrivialStatusOrTime(nt)){
                      hasMeaningfulText=true;
                      break;
                    }
                  }
                }
              }
            }

            if(hasMeaningfulText){
              scheduleReplySettle();
            }
            if(hasElementAdded&&!dotScanTimer){
              dotScanTimer=setTimeout(function(){
                dotScanTimer=null;
                if(!isUserWatching())scanUnreadDots(true);
              },3200);
            }
          });

          obs.observe(document.documentElement,{
            childList:true,
            subtree:true,
            characterData:true
          });
        }

        if(document.documentElement){
          installObserver();
        }else{
          window.addEventListener('DOMContentLoaded',installObserver,{once:true});
        }
        })();
        """#
        return WKUserScript(
            source: js,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
    }

    /// iOS 15–26 WebKit lacks CSS Scroll Anchoring (`overflow-anchor: auto`), causing jarring viewport
    /// jumps when chat WebApps prepend older history (`Loading older messages...`), unmount spinners,
    /// or resize dynamic blocks above the current reading line (and when iOS rubber-band/momentum
    /// clobbers one-shot `scrollTop` adjustments). This isolated-world stabilizer anchors the visible
    /// reading paragraph across DOM prepends and async height updates without interfering with native
    /// 60fps scrolling, bottom streaming auto-follow, or explicit navigation clicks.
    static func scrollAnchorStabilizerScript() -> WKUserScript {
        let js = #"""
        (function(){
        'use strict';
        if(window.__jwScrollAnchorInstalled)return;
        window.__jwScrollAnchorInstalled=true;

        try{
          if(window.CSS&&typeof CSS.supports==='function'&&CSS.supports('overflow-anchor','auto')){
            return;
          }
        }catch(_){}

        var INLINE_TAGS={
          SPAN:1,A:1,CODE:1,STRONG:1,B:1,EM:1,I:1,SMALL:1,SUB:1,SUP:1,
          MARK:1,ABBR:1,TIME:1,SVG:1,PATH:1,G:1,CIRCLE:1,RECT:1,IMG:1,
          BUTTON:1,INPUT:1,TEXTAREA:1,LABEL:1
        };

        var activeScroller=null;
        var anchorEl=null;
        var anchorContentY=0;
        var anchorTextKey='';
        var lastKnownScrollTop=0;
        var lastKnownScrollHeight=0;
        var lastKnownClientHeight=0;
        var lastSnapshotAt=0;
        var scrollIdleTimer=null;

        var isApplyingScroll=false;
        var isTouching=false;
        var lastTouchY=0;
        var suppressUntil=0;
        var bootUntil=Date.now()+1800;
        var lastHref=location.href;

        var prependGuardStartedAt=0;
        var prependGuardUntil=0;
        var lockedRelTop=0;
        var guardRafId=0;
        var postMutateRafId=0;

        var resizeObs=null;
        var observedResizeNodes=new WeakSet();

        function normText(s){
          return String(s||'').replace(/\s+/g,' ').trim();
        }

        function isRootScroller(sc){
          return !sc||sc===document.scrollingElement||sc===document.documentElement||sc===document.body;
        }

        function getViewportRect(sc){
          if(isRootScroller(sc)){
            return{
              top:0,
              left:0,
              width:window.innerWidth||(document.documentElement?document.documentElement.clientWidth:375)||375,
              height:window.innerHeight||(document.documentElement?document.documentElement.clientHeight:667)||667
            };
          }
          return sc.getBoundingClientRect();
        }

        function getScrollTop(sc){
          if(isRootScroller(sc)){
            return window.pageYOffset||(document.documentElement?document.documentElement.scrollTop:0)||(document.body?document.body.scrollTop:0)||0;
          }
          return sc.scrollTop;
        }

        function getClientHeight(sc,vp){
          if(isRootScroller(sc))return vp.height;
          return sc.clientHeight||vp.height;
        }

        function isVerticallyScrollable(el){
          if(!el||el.nodeType!==1)return false;
          if(el===document.documentElement||el===document.body){
            var se=document.scrollingElement||document.documentElement;
            return !!(se&&se.scrollHeight>window.innerHeight+16);
          }
          if(el.clientHeight<80||el.scrollHeight<=el.clientHeight+12)return false;
          var cs=getComputedStyle(el);
          if(!cs)return false;
          var oy=cs.overflowY;
          return oy==='auto'||oy==='scroll'||oy==='overlay';
        }

        function findScrollableAncestor(start){
          var cur=start,depth=0;
          while(cur&&depth<28){
            if(cur.nodeType===1&&isVerticallyScrollable(cur)){
              if(cur===document.body||cur===document.documentElement){
                return document.scrollingElement||document.documentElement;
              }
              return cur;
            }
            var next=cur.parentElement;
            if(!next&&cur.getRootNode){
              var rn=cur.getRootNode();
              if(rn&&rn.host)next=rn.host;
            }
            cur=next;
            depth++;
          }
          var se=document.scrollingElement||document.documentElement;
          if(se&&se.scrollHeight>(window.innerHeight+16))return se;
          return null;
        }

        function ensureScrollerOverscrollContained(sc){
          if(!sc||isRootScroller(sc)||!sc.style)return;
          try{
            if(!sc.style.overscrollBehaviorY){
              sc.style.overscrollBehaviorY='contain';
            }
          }catch(_){}
        }

        function observeScrollerResizes(sc){
          if(!sc||typeof ResizeObserver!=='function')return;
          if(!resizeObs){
            resizeObs=new ResizeObserver(function(){
              if(!activeScroller||isApplyingScroll||document.visibilityState==='hidden')return;
              stabilizeIfNeeded('resize');
            });
          }
          try{
            if(!isRootScroller(sc)&&!observedResizeNodes.has(sc)){
              observedResizeNodes.add(sc);
              resizeObs.observe(sc);
            }
            var kids=sc.children;
            if(kids){
              var n=Math.min(kids.length,4);
              for(var i=0;i<n;i++){
                var c=kids[i];
                if(c&&c.nodeType===1&&!observedResizeNodes.has(c)){
                  observedResizeNodes.add(c);
                  resizeObs.observe(c);
                }
              }
            }
          }catch(_){}
        }

        function isSpinnerOrFloatingOverlay(el,sc,vp){
          var cur=el,d=0;
          while(cur&&cur!==sc&&cur.nodeType===1&&d<14){
            var role=(cur.getAttribute('role')||'').toLowerCase();
            if(role==='progressbar'||role==='status'||cur.getAttribute('aria-busy')==='true')return true;
            var cs=getComputedStyle(cur);
            if(cs){
              if(cs.position==='fixed'||cs.position==='sticky')return true;
              if(cs.position==='absolute'){
                var ar=cur.getBoundingClientRect();
                if(ar.width<vp.width*0.62)return true;
              }
            }
            cur=cur.parentElement;
            d++;
          }
          var txt=normText(el.textContent||'');
          if(txt.length<4)return true;
          if(/^(loading|正在加载|加载中|fetching|please wait)\b/i.test(txt)&&txt.length<64)return true;
          return false;
        }

        function resolveBlockAnchorFromHit(hit,sc,vp){
          if(!hit||hit===sc||!sc.contains(hit))return null;
          var cur=hit,d=0;
          while(cur&&cur!==sc&&cur.nodeType===1&&INLINE_TAGS[cur.tagName]&&d<10){
            cur=cur.parentElement;
            d++;
          }
          if(!cur||cur===sc||cur.nodeType!==1)return null;

          /* If hit landed on a tall multi-message wrapper gap, drill down to the visible child block */
          var downDepth=0;
          while(cur&&cur.children&&cur.children.length>=2&&downDepth<10){
            var cr0=cur.getBoundingClientRect();
            if(cr0.height<=vp.height*0.72)break;
            var bestChild=null;
            var lim=Math.min(cur.children.length,80);
            for(var i=0;i<lim;i++){
              var ch=cur.children[i];
              var chr=ch.getBoundingClientRect();
              if(chr.height>=14&&chr.bottom>(vp.top+44)&&chr.top<(vp.top+vp.height*0.65)){
                if(!isSpinnerOrFloatingOverlay(ch,sc,vp)){
                  bestChild=ch;
                  break;
                }
              }
            }
            if(bestChild)cur=bestChild;
            else break;
            downDepth++;
          }

          /* Climb if block is still too tiny (< 14px) */
          var upDepth=0;
          while(cur&&cur!==sc&&cur.nodeType===1&&upDepth<6){
            var r=cur.getBoundingClientRect();
            if(r.height>=14&&r.width>=48)break;
            cur=cur.parentElement;
            upDepth++;
          }
          if(!cur||cur===sc||cur.nodeType!==1)return null;

          var rect=cur.getBoundingClientRect();
          if(rect.height<14||rect.width<48)return null;
          /* Reject giant list wrapper containing >= 6 children so we never anchor to the whole scroll list */
          if(rect.height>vp.height*1.55&&cur.children&&cur.children.length>=6&&cur.tagName!=='PRE'&&cur.tagName!=='P'){
            return null;
          }
          if(isSpinnerOrFloatingOverlay(cur,sc,vp))return null;

          var txt=normText(cur.textContent||'');
          if(txt.length<4)return null;
          return{
            el:cur,
            relTop:rect.top-vp.top,
            textKey:txt.slice(0,48)
          };
        }

        function pickAnchor(sc,vp){
          var xs=[
            vp.left+Math.round(vp.width*0.36),
            vp.left+Math.round(vp.width*0.52)
          ];
          var ys=[
            vp.top+Math.min(104,Math.round(vp.height*0.20)),
            vp.top+Math.min(164,Math.round(vp.height*0.31)),
            vp.top+Math.min(228,Math.round(vp.height*0.44))
          ];
          for(var yi=0;yi<ys.length;yi++){
            var py=ys[yi];
            if(py<=2||py>=window.innerHeight-4)continue;
            for(var xi=0;xi<xs.length;xi++){
              var px=xs[xi];
              var hit=null;
              try{hit=document.elementFromPoint(px,py);}catch(_){}
              if(!hit)continue;
              var cand=resolveBlockAnchorFromHit(hit,sc,vp);
              if(cand)return cand;
            }
          }
          return null;
        }

        function reacquireAnchorByText(sc,textKey){
          if(!sc||!textKey||textKey.length<6)return null;
          try{
            var nodes=sc.querySelectorAll('p,li,pre,h1,h2,h3,h4,blockquote,div');
            var lim=Math.min(nodes.length,450);
            var best=null;
            var bestH=1e9;
            for(var i=0;i<lim;i++){
              var el=nodes[i];
              if(el.children&&el.children.length>8)continue;
              var t=normText(el.textContent||'');
              if(t.length>=textKey.length&&t.slice(0,textKey.length)===textKey){
                var r=el.getBoundingClientRect();
                if(r.height>=12&&r.height<bestH){
                  best=el;
                  bestH=r.height;
                }
              }
            }
            return best;
          }catch(_){
            return null;
          }
        }

        function refreshAnchorSnapshot(sc,forceRepick){
          if(!sc||!sc.isConnected)return;
          var vp=getViewportRect(sc);
          if(vp.height<80||vp.width<80)return;
          var st=getScrollTop(sc);
          var sh=sc.scrollHeight;
          var ch=getClientHeight(sc,vp);

          lastKnownScrollTop=st;
          lastKnownScrollHeight=sh;
          lastKnownClientHeight=ch;
          lastSnapshotAt=Date.now();

          if(!forceRepick&&anchorEl&&anchorEl.isConnected){
            var r=anchorEl.getBoundingClientRect();
            var rel=r.top-vp.top;
            if(r.height>=14&&rel>=28&&rel<=vp.height*0.54){
              anchorContentY=rel+st;
              return;
            }
          }

          var picked=pickAnchor(sc,vp);
          if(picked){
            anchorEl=picked.el;
            anchorContentY=picked.relTop+st;
            anchorTextKey=picked.textKey;
          }else{
            anchorEl=null;
            anchorTextKey='';
          }
        }

        function applyScrollDeltaInstant(sc,delta){
          if(!sc||Math.abs(delta)<1)return;
          isApplyingScroll=true;
          var targetNode=isRootScroller(sc)?(document.scrollingElement||document.documentElement):sc;
          var prevBehavior=(targetNode&&targetNode.style)?targetNode.style.scrollBehavior:'';
          try{
            if(targetNode&&targetNode.style){
              targetNode.style.setProperty('scroll-behavior','auto','important');
            }
            var curTop=getScrollTop(sc);
            var nextTop=Math.max(0,curTop+delta);
            if(isRootScroller(sc)){
              window.scrollTo(0,nextTop);
            }else{
              sc.scrollTop=nextTop;
            }
          }catch(_){}
          finally{
            if(targetNode&&targetNode.style){
              if(prevBehavior)targetNode.style.scrollBehavior=prevBehavior;
              else targetNode.style.removeProperty('scroll-behavior');
            }
            isApplyingScroll=false;
          }
        }

        function armPrependGuard(sc,relTopNow){
          prependGuardStartedAt=Date.now();
          prependGuardUntil=prependGuardStartedAt+420;
          lockedRelTop=relTopNow;
          if(guardRafId)cancelAnimationFrame(guardRafId);
          var tick=function(){
            guardRafId=0;
            if(!activeScroller||activeScroller!==sc||!sc.isConnected)return;
            if(Date.now()>=prependGuardUntil||Date.now()<suppressUntil)return;
            if(anchorEl&&anchorEl.isConnected){
              var vp=getViewportRect(sc);
              var curRel=anchorEl.getBoundingClientRect().top-vp.top;
              var curSt=getScrollTop(sc);
              var curContentY=curRel+curSt;
              var dContentY=curContentY-anchorContentY;
              if(Math.abs(dContentY)>=2){
                var fix=curRel-lockedRelTop;
                if(Math.abs(fix)>=1.5){
                  applyScrollDeltaInstant(sc,fix);
                }
                var fixedRel=anchorEl.getBoundingClientRect().top-vp.top;
                lastKnownScrollTop=getScrollTop(sc);
                lastKnownScrollHeight=sc.scrollHeight;
                anchorContentY=fixedRel+lastKnownScrollTop;
              }else{
                var elapsed=Date.now()-prependGuardStartedAt;
                var clobberLimit=(!isTouching&&elapsed<95)?48:140;
                var jump=curRel-lockedRelTop;
                if(Math.abs(jump)>=clobberLimit){
                  applyScrollDeltaInstant(sc,jump);
                  var restoredRel=anchorEl.getBoundingClientRect().top-vp.top;
                  lastKnownScrollTop=getScrollTop(sc);
                  anchorContentY=restoredRel+lastKnownScrollTop;
                }else{
                  lockedRelTop=curRel;
                  lastKnownScrollTop=curSt;
                  anchorContentY=curRel+curSt;
                }
              }
            }
            guardRafId=requestAnimationFrame(tick);
          };
          guardRafId=requestAnimationFrame(tick);
        }

        function stabilizeIfNeeded(reason){
          var sc=activeScroller;
          if(!sc||!sc.isConnected||isApplyingScroll)return;
          if(location.href!==lastHref){
            lastHref=location.href;
            anchorEl=null;
            prependGuardUntil=0;
            bootUntil=Date.now()+1600;
            return;
          }
          var now=Date.now();
          if(now<bootUntil||now<suppressUntil){
            refreshAnchorSnapshot(sc,false);
            return;
          }

          var vp=getViewportRect(sc);
          var ch=getClientHeight(sc,vp);
          if(ch<80)return;

          /* Keyboard / viewport resize (> 44px): refresh anchor without fighting iOS keyboard scroll */
          if(lastKnownClientHeight>0&&Math.abs(ch-lastKnownClientHeight)>44){
            observeScrollerResizes(sc);
            refreshAnchorSnapshot(sc,false);
            return;
          }

          /* Page wasn't scrollable yet before this mutation (initial hydration) */
          if(lastKnownScrollHeight<=ch+20){
            observeScrollerResizes(sc);
            refreshAnchorSnapshot(sc,true);
            return;
          }

          /* Do not hold back bottom auto-follow when user was pinned at the bottom of a long chat */
          var prevMaxScroll=lastKnownScrollHeight-lastKnownClientHeight;
          if(prevMaxScroll>60&&lastKnownScrollTop>160&&(prevMaxScroll-lastKnownScrollTop)<110){
            refreshAnchorSnapshot(sc,false);
            return;
          }

          var expectedRelTop=(now<prependGuardUntil)?lockedRelTop:(anchorContentY-lastKnownScrollTop);
          /* Ensure anchor was actually near the user's viewport right before mutation */
          if(expectedRelTop<-ch*0.5||expectedRelTop>ch*1.15){
            refreshAnchorSnapshot(sc,true);
            return;
          }

          if(!anchorEl||!anchorEl.isConnected){
            var reacquired=reacquireAnchorByText(sc,anchorTextKey);
            if(reacquired){
              anchorEl=reacquired;
            }else{
              var dH=sc.scrollHeight-lastKnownScrollHeight;
              if(dH>80&&lastKnownScrollTop<420&&anchorTextKey.length>=6){
                var savedTargetRel=expectedRelTop;
                var savedKey=anchorTextKey;
                applyScrollDeltaInstant(sc,dH);
                lastKnownScrollTop=getScrollTop(sc);
                lastKnownScrollHeight=sc.scrollHeight;
                requestAnimationFrame(function(){
                  if(!sc.isConnected)return;
                  var vp2=getViewportRect(sc);
                  var found2=reacquireAnchorByText(sc,savedKey);
                  if(found2){
                    anchorEl=found2;
                    var r2=found2.getBoundingClientRect();
                    var curRel2=r2.top-vp2.top;
                    var fix2=curRel2-savedTargetRel;
                    if(Math.abs(fix2)>=2){
                      applyScrollDeltaInstant(sc,fix2);
                    }
                    var finalRel=found2.getBoundingClientRect().top-vp2.top;
                    lastKnownScrollTop=getScrollTop(sc);
                    lastKnownScrollHeight=sc.scrollHeight;
                    anchorContentY=finalRel+lastKnownScrollTop;
                    armPrependGuard(sc,finalRel);
                  }else{
                    refreshAnchorSnapshot(sc,true);
                  }
                });
                return;
              }
              refreshAnchorSnapshot(sc,true);
              return;
            }
          }

          var rNow=anchorEl.getBoundingClientRect();
          if(rNow.height<4){
            refreshAnchorSnapshot(sc,true);
            return;
          }
          var curRelTop=rNow.top-vp.top;
          var curSt=getScrollTop(sc);
          var curContentY=curRelTop+curSt;
          var dContentY=curContentY-anchorContentY;

          if(Math.abs(dContentY)<2){
            lastKnownScrollHeight=sc.scrollHeight;
            return;
          }

          var visualDelta=curRelTop-expectedRelTop;
          if(Math.abs(visualDelta)>=1.5){
            applyScrollDeltaInstant(sc,visualDelta);
          }

          var afterRect=anchorEl.getBoundingClientRect();
          var afterRelTop=afterRect.top-vp.top;
          lastKnownScrollTop=getScrollTop(sc);
          lastKnownScrollHeight=sc.scrollHeight;
          lastKnownClientHeight=ch;
          anchorContentY=afterRelTop+lastKnownScrollTop;

          if(Math.abs(dContentY)>=40){
            observeScrollerResizes(sc);
            armPrependGuard(sc,expectedRelTop);
          }
        }

        /* Passive touch & scroll tracking */
        var touchStartY=0;
        document.addEventListener('touchstart',function(ev){
          if(!ev.touches||ev.touches.length!==1)return;
          isTouching=true;
          touchStartY=ev.touches[0].clientY;
          lastTouchY=touchStartY;
          var sc=findScrollableAncestor(ev.target);
          if(sc){
            ensureScrollerOverscrollContained(sc);
            observeScrollerResizes(sc);
            if(sc!==activeScroller){
              activeScroller=sc;
              prependGuardUntil=0;
              refreshAnchorSnapshot(sc,true);
            }else if(!anchorEl||!anchorEl.isConnected){
              refreshAnchorSnapshot(sc,true);
            }
          }
        },{capture:true,passive:true});

        document.addEventListener('touchmove',function(ev){
          if(!isTouching||!ev.touches||ev.touches.length!==1)return;
          var y=ev.touches[0].clientY;
          var dy=y-lastTouchY;
          lastTouchY=y;
          if(Math.abs(y-touchStartY)>10&&(bootUntil>0||suppressUntil>0)){
            bootUntil=0;
            suppressUntil=0;
            if(activeScroller&&(!anchorEl||!anchorEl.isConnected)){
              refreshAnchorSnapshot(activeScroller,true);
            }
          }
          if(Date.now()<prependGuardUntil){
            lockedRelTop+=dy;
          }
        },{capture:true,passive:true});

        function onTouchEnd(){
          isTouching=false;
          if(activeScroller&&Date.now()>=prependGuardUntil){
            refreshAnchorSnapshot(activeScroller,false);
          }
        }
        document.addEventListener('touchend',onTouchEnd,{capture:true,passive:true});
        document.addEventListener('touchcancel',onTouchEnd,{capture:true,passive:true});

        /* Suppress anchoring on intentional navigation / scroll-to-bottom / disclosure clicks */
        document.addEventListener('click',function(ev){
          var cur=ev&&ev.target,d=0;
          while(cur&&cur.nodeType===1&&d<7){
            var tag=cur.tagName;
            var role=(cur.getAttribute('role')||'').toLowerCase();
            if(tag==='BUTTON'||tag==='A'||tag==='SUMMARY'||role==='button'||role==='tab'||role==='menuitem'||role==='option'){
              var label=normText((cur.getAttribute('aria-label')||'')+' '+(cur.getAttribute('title')||'')+' '+(cur.textContent||''));
              if(/load\s*(older|more|previous|earlier)|加载(更多|更早|历史)|历史消息|查看更多/i.test(label)){
                if(activeScroller)refreshAnchorSnapshot(activeScroller,false);
              }else{
                suppressUntil=Date.now()+650;
                prependGuardUntil=0;
                anchorEl=null;
              }
              break;
            }
            cur=cur.parentElement;
            d++;
          }
        },true);

        document.addEventListener('keydown',function(ev){
          if(ev&&ev.key==='Enter'&&!ev.shiftKey&&!ev.isComposing){
            var t=ev.target;
            if(t&&(t.tagName==='TEXTAREA'||t.tagName==='INPUT'||t.isContentEditable)){
              suppressUntil=Date.now()+900;
              prependGuardUntil=0;
              anchorEl=null;
            }
          }
        },true);

        document.addEventListener('scroll',function(ev){
          if(isApplyingScroll)return;
          var target=ev.target;
          var sc=null;
          if(target===document||target===document.documentElement||target===document.body){
            sc=document.scrollingElement||document.documentElement;
          }else if(target&&target.nodeType===1){
            if(target.clientHeight<80||target.scrollHeight<=target.clientHeight+12)return;
            sc=target;
          }
          if(!sc)return;

          if(sc!==activeScroller){
            activeScroller=sc;
            prependGuardUntil=0;
            ensureScrollerOverscrollContained(sc);
            observeScrollerResizes(sc);
            refreshAnchorSnapshot(sc,true);
            return;
          }

          if(Math.abs(sc.scrollHeight-lastKnownScrollHeight)>=2){
            stabilizeIfNeeded('scroll-sh');
            return;
          }

          var now=Date.now();
          if(now<prependGuardUntil&&anchorEl&&anchorEl.isConnected){
            var vp=getViewportRect(sc);
            var curRel=anchorEl.getBoundingClientRect().top-vp.top;
            var curSt=getScrollTop(sc);
            var curContentY=curRel+curSt;
            if(Math.abs(curContentY-anchorContentY)>=2){
              stabilizeIfNeeded('scroll-guard-layout');
              return;
            }
            var elapsed=now-prependGuardStartedAt;
            var clobberLimit=(!isTouching&&elapsed<95)?48:140;
            var diff=curRel-lockedRelTop;
            if(Math.abs(diff)>=clobberLimit){
              applyScrollDeltaInstant(sc,diff);
              var fixedRel=anchorEl.getBoundingClientRect().top-vp.top;
              lastKnownScrollTop=getScrollTop(sc);
              anchorContentY=fixedRel+lastKnownScrollTop;
              return;
            }
            lockedRelTop=curRel;
            lastKnownScrollTop=curSt;
            anchorContentY=curRel+curSt;
            return;
          }

          lastKnownScrollTop=getScrollTop(sc);
          if(now-lastSnapshotAt>=90){
            refreshAnchorSnapshot(sc,false);
          }
          if(scrollIdleTimer)clearTimeout(scrollIdleTimer);
          scrollIdleTimer=setTimeout(function(){
            scrollIdleTimer=null;
            if(activeScroller&&Date.now()>=prependGuardUntil){
              refreshAnchorSnapshot(activeScroller,false);
            }
          },130);
        },{capture:true,passive:true});

        function installMutationHook(){
          if(!document.documentElement)return;
          var mo=new MutationObserver(function(mutations){
            if(!activeScroller||isApplyingScroll||document.visibilityState==='hidden')return;
            if(location.href!==lastHref){
              stabilizeIfNeeded('href');
              return;
            }
            var relevant=false;
            var rootSc=isRootScroller(activeScroller);
            for(var i=0;i<mutations.length;i++){
              var m=mutations[i];
              if(!m.target)continue;
              if(rootSc||m.target===activeScroller||activeScroller.contains(m.target)){
                relevant=true;
                break;
              }
            }
            if(!relevant)return;
            stabilizeIfNeeded('mutation');
            if(!postMutateRafId){
              postMutateRafId=requestAnimationFrame(function(){
                postMutateRafId=0;
                stabilizeIfNeeded('post-mutation-raf');
              });
            }
          });
          mo.observe(document.documentElement,{childList:true,subtree:true});
        }

        if(document.documentElement){
          installMutationHook();
        }else{
          window.addEventListener('DOMContentLoaded',installMutationHook,{once:true});
        }
        })();
        """#
        return WKUserScript(
            source: js,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .defaultClient
        )
    }

    /// SPA-safe page-level JS retention cleanup invoked right before WebKit/JSC memory pressure GC.
    /// Clears PerformanceObserver/ResourceTiming/UserTiming buffers and retained console object graphs
    /// without mutating virtual-DOM trees, scroll positions, draft inputs, or live WebSockets.
    static func memoryReliefHelperScript() -> WKUserScript {
        let js = #"""
        (function(){
        'use strict';
        if(window.__jwMemReliefInstalled)return;
        window.__jwMemReliefInstalled=true;
        window.__jwTrimPageMemory=function(opts){
          try{
            var o=opts||{};
            if(window.performance){
              if(typeof performance.clearResourceTimings==='function')performance.clearResourceTimings();
              if(o.aggressive){
                if(typeof performance.clearMarks==='function')performance.clearMarks();
                if(typeof performance.clearMeasures==='function')performance.clearMeasures();
              }
            }
            if(o.aggressive&&typeof console!=='undefined'&&console&&typeof console.clear==='function'){
              try{console.clear();}catch(_){}
            }
            if(o.hiddenTab&&window.getSelection){
              var ae=document.activeElement;
              var tag=ae&&ae.tagName?ae.tagName:'';
              var editing=!!(ae&&(tag==='INPUT'||tag==='TEXTAREA'||ae.isContentEditable));
              if(!editing){
                var sel=window.getSelection();
                if(sel&&sel.rangeCount>0&&sel.isCollapsed){sel.removeAllRanges();}
              }
            }
          }catch(_){}
        };
        })();
        """#
        return WKUserScript(
            source: js,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
    }
}

