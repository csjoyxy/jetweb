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
    /// Modern ES2023–ES2026 & Web scheduling compatibility layer (aligned with JetBrowser's WebCompatEngine).
    /// Runs in `.page` world with zero DOM observers and zero prototype conflicts.
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
          if(typeof AbortSignal==='function'&&typeof AbortSignal.timeout!=='function'){
            Object.defineProperty(AbortSignal,'timeout',{configurable:true,writable:true,value:function timeout(ms){
              var ctrl=new AbortController();
              setTimeout(function(){
                var err;
                try{err=new DOMException('The operation timed out.','TimeoutError');}catch(_){err=new Error('TimeoutError');}
                ctrl.abort(err);
              },Math.max(0,Number(ms)||0));
              return ctrl.signal;
            }});
          }
          if(typeof window.requestIdleCallback!=='function'){
            window.requestIdleCallback=function requestIdleCallback(cb,opts){
              var start=Date.now();
              var delay=(opts&&typeof opts.timeout==='number'&&opts.timeout>0)?Math.min(50,opts.timeout):1;
              return setTimeout(function(){
                cb({didTimeout:false,timeRemaining:function(){return Math.max(0,50-(Date.now()-start));}});
              },delay);
            };
            window.cancelIdleCallback=function cancelIdleCallback(id){clearTimeout(id);};
          }
          if(!window.scheduler){
            window.scheduler={};
          }
          if(typeof window.scheduler.yield!=='function'){
            window.scheduler.yield=function schedulerYield(){
              return new Promise(function(resolve){setTimeout(resolve,0);});
            };
          }
          if(typeof window.scheduler.postTask!=='function'){
            window.scheduler.postTask=function postTask(cb,opts){
              var o=opts||{};
              var sig=o.signal;
              var delay=Math.max(0,Number(o.delay)||0);
              return new Promise(function(resolve,reject){
                if(sig&&sig.aborted){reject(sig.reason);return;}
                var tid=setTimeout(function(){
                  if(sig)sig.removeEventListener('abort',onAbort);
                  try{resolve(cb());}catch(e){reject(e);}
                },delay);
                function onAbort(){
                  clearTimeout(tid);
                  reject(sig.reason);
                }
                if(sig)sig.addEventListener('abort',onAbort,{once:true});
              });
            };
          }
          if(typeof ReadableStream==='function'&&ReadableStream.prototype&&typeof Symbol==='function'&&Symbol.asyncIterator&&!ReadableStream.prototype[Symbol.asyncIterator]){
            var rsValues=function values(opts){
              var reader=this.getReader();
              var preventCancel=!!(opts&&opts.preventCancel);
              var doneReleased=false;
              return{
                next:function(){
                  return reader.read().then(function(res){
                    if(res.done&&!doneReleased){doneReleased=true;try{reader.releaseLock();}catch(_){}}
                    return res;
                  },function(err){
                    if(!doneReleased){doneReleased=true;try{reader.releaseLock();}catch(_){}}
                    throw err;
                  });
                },
                return:function(val){
                  if(!doneReleased){
                    doneReleased=true;
                    if(!preventCancel){
                      var p=reader.cancel(val);
                      try{reader.releaseLock();}catch(_){}
                      return Promise.resolve(p).then(function(){return{done:true,value:val};});
                    }
                    try{reader.releaseLock();}catch(_){}
                  }
                  return Promise.resolve({done:true,value:val});
                },
                [Symbol.asyncIterator]:function(){return this;}
              };
            };
            Object.defineProperty(ReadableStream.prototype,'values',{configurable:true,writable:true,value:rsValues});
            Object.defineProperty(ReadableStream.prototype,Symbol.asyncIterator,{configurable:true,writable:true,value:rsValues});
          }
          if(typeof Set==='function'&&Set.prototype&&typeof Set.prototype.union!=='function'){
            var defSet=function(n,fn){if(typeof Set.prototype[n]!=='function')Object.defineProperty(Set.prototype,n,{configurable:true,writable:true,value:fn});};
            defSet('union',function(o){var r=new Set(this);if(o){if(typeof o.keys==='function'){var it=o.keys(),s;while(!(s=it.next()).done)r.add(s.value);}else{for(var x of o)r.add(x);}}return r;});
            defSet('intersection',function(o){var r=new Set();if(o&&typeof o.has==='function'){this.forEach(function(v){if(o.has(v))r.add(v);});}return r;});
            defSet('difference',function(o){var r=new Set(this);if(o&&typeof o.has==='function'){this.forEach(function(v){if(o.has(v))r.delete(v);});}return r;});
            defSet('symmetricDifference',function(o){var r=new Set(this);if(o&&typeof o.keys==='function'){var it=o.keys(),s;while(!(s=it.next()).done){if(this.has(s.value))r.delete(s.value);else r.add(s.value);}}return r;});
            defSet('isSubsetOf',function(o){if(!o||typeof o.has!=='function')return false;var it=this.values(),s;while(!(s=it.next()).done){if(!o.has(s.value))return false;}return true;});
            defSet('isSupersetOf',function(o){if(!o||typeof o.keys!=='function')return false;var it=o.keys(),s;while(!(s=it.next()).done){if(!this.has(s.value))return false;}return true;});
            defSet('isDisjointFrom',function(o){if(!o||typeof o.has!=='function')return true;var it=this.values(),s;while(!(s=it.next()).done){if(o.has(s.value))return false;}return true;});
          }
          if(Array.prototype){
            var defArr=function(n,fn){if(typeof Array.prototype[n]!=='function')Object.defineProperty(Array.prototype,n,{configurable:true,writable:true,value:fn});};
            defArr('at',function(i){var len=this.length>>>0,k=Math.trunc(i)||0;if(k<0)k+=len;return(k<0||k>=len)?undefined:this[k];});
            defArr('findLast',function(cb,thisArg){for(var i=(this.length>>>0)-1;i>=0;i--){if(cb.call(thisArg,this[i],i,this))return this[i];}return undefined;});
            defArr('findLastIndex',function(cb,thisArg){for(var i=(this.length>>>0)-1;i>=0;i--){if(cb.call(thisArg,this[i],i,this))return i;}return -1;});
            defArr('toReversed',function(){return Array.from(this).reverse();});
            defArr('toSorted',function(cmp){var a=Array.from(this);return cmp!==undefined?a.sort(cmp):a.sort();});
            defArr('toSpliced',function(start,delCount){var a=Array.from(this),args=[start,arguments.length<2?a.length:delCount];for(var i=2;i<arguments.length;i++)args.push(arguments[i]);a.splice.apply(a,args);return a;});
            defArr('with',function(idx,val){var a=Array.from(this),len=a.length,k=Math.trunc(idx)||0;if(k<0)k+=len;if(k<0||k>=len)throw new RangeError('Invalid index');a[k]=val;return a;});
          }
          if(typeof Symbol==='function'&&Symbol.iterator){
            var iterProto=Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]()));
            if(iterProto&&typeof iterProto.toArray!=='function'){
              var wrapIter=function(genFn){return function(){return genFn.apply(this,arguments);};};
              var defIt=function(n,fn){if(typeof iterProto[n]!=='function')Object.defineProperty(iterProto,n,{configurable:true,writable:true,value:fn});};
              defIt('toArray',function(){var out=[],s;while(!(s=this.next()).done)out.push(s.value);return out;});
              defIt('forEach',function(fn){var i=0,s;while(!(s=this.next()).done)fn(s.value,i++);});
              defIt('some',function(fn){var i=0,s;while(!(s=this.next()).done){if(fn(s.value,i++)){if(typeof this.return==='function')try{this.return();}catch(_){}return true;}}return false;});
              defIt('every',function(fn){var i=0,s;while(!(s=this.next()).done){if(!fn(s.value,i++)){if(typeof this.return==='function')try{this.return();}catch(_){}return false;}}return true;});
              defIt('find',function(fn){var i=0,s;while(!(s=this.next()).done){if(fn(s.value,i++)){if(typeof this.return==='function')try{this.return();}catch(_){}return s.value;}}return undefined;});
              defIt('reduce',function(fn,init){var hasInit=arguments.length>=2,acc=init,i=0,s;while(!(s=this.next()).done){if(!hasInit){acc=s.value;hasInit=true;i++;continue;}acc=fn(acc,s.value,i++);}if(!hasInit)throw new TypeError('Reduce of empty iterator with no initial value');return acc;});
              defIt('map',wrapIter(function*(fn){var i=0,s;try{while(!(s=this.next()).done)yield fn(s.value,i++);}finally{if(!s||!s.done)if(typeof this.return==='function')try{this.return();}catch(_){}}}));
              defIt('filter',wrapIter(function*(fn){var i=0,s;try{while(!(s=this.next()).done){if(fn(s.value,i++))yield s.value;}}finally{if(!s||!s.done)if(typeof this.return==='function')try{this.return();}catch(_){}}}));
              defIt('take',wrapIter(function*(lim){var n=Math.max(0,Math.trunc(lim)||0),i=0,s;try{while(i++<n&&!(s=this.next()).done)yield s.value;}finally{if((!s||!s.done)&&typeof this.return==='function')try{this.return();}catch(_){}}}));
              defIt('drop',wrapIter(function*(lim){var n=Math.max(0,Math.trunc(lim)||0),i=0,s;try{while(i++<n&&!(s=this.next()).done){}while(!(s=this.next()).done)yield s.value;}finally{if((!s||!s.done)&&typeof this.return==='function')try{this.return();}catch(_){}}}));
              defIt('flatMap',wrapIter(function*(fn){var i=0,s;try{while(!(s=this.next()).done){var sub=fn(s.value,i++);if(sub!=null&&typeof sub[Symbol.iterator]==='function'){for(var x of sub)yield x;}else if(sub&&typeof sub.next==='function'){var t;while(!(t=sub.next()).done)yield t.value;}}}finally{if((!s||!s.done)&&typeof this.return==='function')try{this.return();}catch(_){}}}));
              if(typeof window.Iterator==='undefined'){
                var JWIterator=function(){};
                JWIterator.prototype=iterProto;
                JWIterator.from=function(v){
                  if(v!=null&&typeof v[Symbol.iterator]==='function')return v[Symbol.iterator]();
                  if(v&&typeof v.next==='function'){
                    if(iterProto.isPrototypeOf(v))return v;
                    var w=Object.create(iterProto);
                    w.next=function(){return v.next();};
                    w.return=function(x){return typeof v.return==='function'?v.return(x):{done:true,value:x};};
                    w[Symbol.iterator]=function(){return this;};
                    return w;
                  }
                  throw new TypeError('Object is not iterable');
                };
                window.Iterator=JWIterator;
              }
            }
          }
          if(typeof RegExp==='function'&&typeof RegExp.escape!=='function'){
            Object.defineProperty(RegExp,'escape',{configurable:true,writable:true,value:function escape(s){
              return String(s).replace(/[\\^$.*+?()[\]{}|/\-]/g,'\\$&');
            }});
          }
          if(typeof Error==='function'&&typeof Error.isError!=='function'){
            Object.defineProperty(Error,'isError',{configurable:true,writable:true,value:function isError(v){
              return v instanceof Error||Object.prototype.toString.call(v)==='[object Error]';
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

    /// Event-driven input contrast guard running strictly in `.page` (main frame only) so WebKit
    /// never allocates a duplicate `.defaultClient` DOMWrapperWorld across large SPA DOM trees.
    static func inputContrastFixScript() -> WKUserScript {
        let js = #"""
        (function(){
        'use strict';
        if(window.__jwContrastFixInstalled)return;
        window.__jwContrastFixInstalled=true;
        var SKIP_TYPES={hidden:1,checkbox:1,radio:1,button:1,submit:1,reset:1,image:1,file:1,range:1,color:1};
        var patched=new WeakMap();
        var patchedRefs=[];
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
          while(node&&node.nodeType===1&&depth<32){
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
          if(patchedRefs.length<16&&patchedRefs.indexOf(el)===-1){
            patchedRefs.push(el);
          }
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
        },true);
        document.addEventListener('input',function(ev){checkAndFix(eventTarget(ev));},true);
        document.addEventListener('change',function(ev){checkAndFix(eventTarget(ev));},true);
        document.addEventListener('blur',function(ev){
          var t=eventTarget(ev);
          if(isTextInput(t)&&patched.has(t)){checkAndFix(t);}
        },true);
        window.__jwRecheckInputs=function(){
          try{
            if(document.activeElement&&isTextInput(document.activeElement)){
              checkAndFix(document.activeElement);
            }
            for(var i=patchedRefs.length-1;i>=0;i--){
              var el=patchedRefs[i];
              if(!el||!el.isConnected){patchedRefs.splice(i,1);continue;}
              checkAndFix(el);
            }
          }catch(_){}
        };
        try{
          var mq=window.matchMedia('(prefers-color-scheme: dark)');
          if(mq&&mq.addEventListener)mq.addEventListener('change',function(){setTimeout(window.__jwRecheckInputs,60);});
        }catch(_){}
        })();
        """#
        return WKUserScript(
            source: js,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .page
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
            forMainFrameOnly: true,
            in: .page
        )
    }

    /// Zero-foreground-overhead background conversation monitor:
    /// - Attaches ZERO `MutationObserver`s and runs ZERO DOM layout queries during page load,
    ///   SPA hydration, scrolling, or foreground viewing (`isUserWatching() == true`).
    /// - Does NOT override `window.Notification` or `Element.prototype.attachShadow`, preserving
    ///   100% stock Safari / JetBrowser global API parity for Google / Lit / React SPAs.
    /// - Connects a bounded `MutationObserver` ONLY while the tab is in the background or unselected,
    ///   and disconnects it immediately upon returning to foreground.
    static func conversationMonitorScript() -> WKUserScript {
        let js = #"""
        (function(){
        'use strict';
        if(window.__jwNotifyInstalled)return;
        window.__jwNotifyInstalled=true;

        var hostState={appActive:true,tabSelected:true};
        var lastComposerText='';
        var lastComposerInputAt=0;
        var lastUserSentAt=0;
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
        var sharedMutObs=null;
        var obsConnected=false;
        var bgEnteredAt=0;

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

        function normShortText(s){
          if(!s)return '';
          var clipped=s.length>420?s.slice(0,420):s;
          return clipped.replace(/\s+/g,' ').trim();
        }

        function safeLeafText(el,maxChildren){
          if(!el||el.nodeType!==1)return '';
          var lim=maxChildren||5;
          if(typeof el.childElementCount==='number'&&el.childElementCount>lim)return '';
          var raw=el.textContent;
          if(!raw||raw.length>1800)return '';
          return normShortText(raw);
        }

        function isTrivialStatusOrTime(t){
          if(!t||t.length<2)return true;
          if(/^(\d+\s*(s|sec|m|min|h|hr|d|秒|分钟|小时|天)(\s*ago|前)?|just now|刚刚|剛剛|\d{1,2}:\d{2}(\s*[ap]m)?)$/i.test(t))return true;
          if(/^(thinking|analyzing|generating|loading|working|running|searching|思考中|正在输入|加载中)[.…·\s]*$/i.test(t))return true;
          return false;
        }

        function isInsideIgnoredChrome(el){
          var cur=el,d=0;
          while(cur&&cur.nodeType===1&&d<14){
            var tag=cur.tagName;
            if(tag==='NAV'||tag==='ASIDE'||tag==='HEADER'||tag==='FOOTER'||tag==='SCRIPT'||tag==='STYLE'||tag==='SVG'||tag==='TEXTAREA'||tag==='INPUT'||tag==='BUTTON'){
              return true;
            }
            if(cur.isContentEditable)return true;
            var role=(cur.getAttribute('role')||'').toLowerCase();
            if(role==='navigation'||role==='textbox'||role==='combobox'||role==='dialog')return true;
            cur=cur.parentElement;
            d++;
          }
          return false;
        }

        function captureLatestChatSnippet(){
          try{
            if(!document.body)return '';
            var root=document.querySelector('main,[role="main"],[role="log"]')||document.body;
            var blocks=root.querySelectorAll('p,li,pre,blockquote,[data-message-author-role="assistant"] p,[class*="markdown" i] p,[class*="prose" i] p');
            var best='';
            for(var i=blocks.length-1;i>=Math.max(0,blocks.length-28);i--){
              var el=blocks[i];
              if(isInsideIgnoredChrome(el))continue;
              var txt=safeLeafText(el,6);
              if(txt.length>=4&&!isTrivialStatusOrTime(txt)&&txt!==lastComposerText){
                best=txt;
                break;
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

        function extractRowTitleForDot(dotEl){
          var cur=dotEl.parentElement,d=0;
          while(cur&&cur.nodeType===1&&cur!==document.body&&d<5){
            var raw=safeLeafText(cur,5);
            if(raw.length>=2&&raw.length<=95){
              raw=raw.replace(/\b\d+\s*(s|m|h|d|min|hr)\b$/i,'').trim();
              if(raw.length>=2&&!isTrivialStatusOrTime(raw))return raw;
            }
            cur=cur.parentElement;
            d++;
          }
          return '';
        }

        function scanUnreadDots(allowEmit){
          try{
            if(!document.body)return;
            var currentSet=new Set();
            var explicit=document.querySelectorAll('[aria-label*="unread" i],[data-unread="true"],[title*="未读"]');
            var lim=Math.min(explicit.length,40);
            for(var i=0;i<lim;i++){
              var rt=extractRowTitleForDot(explicit[i])||safeLeafText(explicit[i],4);
              if(rt.length>=2&&rt.length<=95)currentSet.add(rt);
            }
            if(allowEmit&&!isUserWatching()&&(Date.now()-bgEnteredAt)>1500){
              currentSet.forEach(function(title){
                if(!knownUnreadTitles.has(title)&&(Date.now()-lastNotifiedAt)>=6000){
                  lastNotifiedAt=Date.now();
                  postNative({
                    k:'unread_dot',
                    sub:'新对话动态',
                    body:'「'+title+'」有新回复待查看'
                  });
                }
              });
            }
            knownUnreadTitles=currentSet;
          }catch(_){}
        }

        function isBusyGenerating(){
          if(streamStartedAt>0&&(Date.now()-streamStartedAt)>600000)return false;
          try{
            if(!document.body)return false;
            var btns=document.querySelectorAll('button[aria-label*="stop" i],button[aria-label*="停止"],button[title*="stop" i],button[title*="停止"],[role="button"][aria-label*="stop" i]');
            for(var i=0;i<btns.length&&i<12;i++){
              if(!btns[i].disabled)return true;
            }
          }catch(_){}
          return false;
        }

        function checkReplySettled(){
          settleTimer=null;
          if(!pendingReply||isUserWatching()){
            pendingReply=false;
            streamStartedAt=0;
            return;
          }
          if(isBusyGenerating()){
            settleTimer=setTimeout(checkReplySettled,2200);
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
          if(isUserWatching())return;
          if(!pendingReply){
            pendingReply=true;
            streamStartedAt=Date.now();
          }
          if((Date.now()-lastStreamPingAt)>12000){
            lastStreamPingAt=Date.now();
            postNative({k:'streaming'});
          }
          if(settleTimer)clearTimeout(settleTimer);
          settleTimer=setTimeout(checkReplySettled,3200);
        }

        function checkTitleBadge(){
          var t=normShortText(document.title||'');
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

        function ensureBackgroundObserver(){
          if(isUserWatching()){
            if(obsConnected&&sharedMutObs){
              sharedMutObs.disconnect();
              obsConnected=false;
            }
            if(settleTimer){clearTimeout(settleTimer);settleTimer=null;}
            if(dotScanTimer){clearTimeout(dotScanTimer);dotScanTimer=null;}
            pendingReply=false;
            streamStartedAt=0;
            return;
          }
          if(obsConnected||!document.body)return;
          if(!sharedMutObs){
            sharedMutObs=new MutationObserver(function(mutations){
              if(isUserWatching()){
                ensureBackgroundObserver();
                return;
              }
              var hasMeaningfulText=false;
              var hasElementAdded=false;
              var lim=Math.min(mutations.length,60);
              for(var i=0;i<lim;i++){
                var m=mutations[i];
                if(m.target&&m.target.nodeName==='TITLE'){
                  checkTitleBadge();
                  continue;
                }
                if(m.type==='characterData'){
                  var p=m.target?m.target.parentElement:null;
                  if(p&&!isInsideIgnoredChrome(p)){
                    var t=normShortText(m.target.nodeValue||'');
                    if(t.length>=3&&!isTrivialStatusOrTime(t)){
                      hasMeaningfulText=true;
                      break;
                    }
                  }
                }else if(m.type==='childList'&&m.addedNodes&&m.addedNodes.length>0){
                  hasElementAdded=true;
                  if(!hasMeaningfulText&&m.target&&m.target.nodeType===1&&!isInsideIgnoredChrome(m.target)){
                    var nLim=Math.min(m.addedNodes.length,8);
                    for(var k=0;k<nLim;k++){
                      var nd=m.addedNodes[k];
                      var nt=(nd.nodeType===3)?normShortText(nd.nodeValue||''):safeLeafText(nd,5);
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
                },3500);
              }
            });
          }
          try{
            sharedMutObs.observe(document.body,{childList:true,subtree:true,characterData:true});
            var titleEl=document.querySelector('head > title');
            if(titleEl)sharedMutObs.observe(titleEl,{childList:true,subtree:true,characterData:true});
            obsConnected=true;
          }catch(_){}
        }

        function emitUserSentIfNeeded(){
          var now=Date.now();
          if(now-lastUserSentAt<2500)return;
          lastUserSentAt=now;
          postNative({k:'user_sent'});
        }

        function getEventPath(ev){
          if(ev&&typeof ev.composedPath==='function'){
            var p=ev.composedPath();
            if(p&&p.length)return p;
          }
          var out=[],cur=ev?ev.target:null,d=0;
          while(cur&&d<10){out.push(cur);cur=cur.parentElement;d++;}
          return out;
        }

        function isEditableTarget(el){
          if(!el||el.nodeType!==1)return false;
          var tag=el.tagName;
          if(tag==='TEXTAREA'||tag==='INPUT'||el.isContentEditable)return true;
          var role=(el.getAttribute('role')||'').toLowerCase();
          return role==='textbox';
        }

        document.addEventListener('input',function(ev){
          var path=getEventPath(ev);
          var lim=Math.min(path.length,6);
          for(var i=0;i<lim;i++){
            var el=path[i];
            if(isEditableTarget(el)){
              var raw=(typeof el.value==='string')?el.value:(el.textContent||'');
              var v=normShortText(raw);
              lastComposerInputAt=Date.now();
              if(v.length>=2){
                lastComposerText=v.length>120?(v.slice(0,120)+'…'):v;
              }
              break;
            }
          }
        },{capture:true,passive:true});

        document.addEventListener('keydown',function(ev){
          if(!ev||ev.key!=='Enter'||ev.shiftKey||ev.isComposing)return;
          var path=getEventPath(ev);
          var lim=Math.min(path.length,6);
          for(var i=0;i<lim;i++){
            if(isEditableTarget(path[i])){
              emitUserSentIfNeeded();
              break;
            }
          }
        },{capture:true,passive:true});

        function checkButtonSendFromEvent(ev){
          var path=getEventPath(ev);
          var lim=Math.min(path.length,8);
          for(var i=0;i<lim;i++){
            var cur=path[i];
            if(!cur||cur.nodeType!==1)continue;
            if(cur.tagName==='BUTTON'||cur.getAttribute('role')==='button'){
              var tp=(cur.getAttribute('type')||'').toLowerCase();
              var lb=((cur.getAttribute('aria-label')||'')+' '+(cur.getAttribute('title')||'')+' '+(cur.getAttribute('data-testid')||'')+' '+safeLeafText(cur,3)).toLowerCase();
              if(tp==='submit'||/send|submit|发送|提交|ask|up-arrow|arrow_upward|north/.test(lb)){
                emitUserSentIfNeeded();
              }else if((Date.now()-lastComposerInputAt)<60000&&!/cancel|close|attach|upload|voice|mic|menu|sidebar|copy|stop|more|add|plus|取消|关闭|上传|菜单|复制|停止|更多/.test(lb)){
                emitUserSentIfNeeded();
              }
              break;
            }
          }
        }
        document.addEventListener('click',checkButtonSendFromEvent,{capture:true,passive:true});
        document.addEventListener('pointerup',checkButtonSendFromEvent,{capture:true,passive:true});

        window.__jwUpdateHostState=function(st){
          var wasWatching=isUserWatching();
          if(st&&typeof st.appActive==='boolean')hostState.appActive=st.appActive;
          if(st&&typeof st.tabSelected==='boolean')hostState.tabSelected=st.tabSelected;
          var nowWatching=isUserWatching();
          if(wasWatching&&!nowWatching){
            bgEnteredAt=Date.now();
            lastBaselineTail=captureLatestChatSnippet();
            scanUnreadDots(false);
            ensureBackgroundObserver();
            if(isBusyGenerating()||(Date.now()-lastUserSentAt)<180000){
              scheduleReplySettle();
            }
          }else if(!nowWatching&&!obsConnected&&document.body){
            bgEnteredAt=Date.now();
            lastBaselineTail=captureLatestChatSnippet();
            scanUnreadDots(false);
            ensureBackgroundObserver();
          }else if(nowWatching&&obsConnected){
            ensureBackgroundObserver();
          }
        };

        document.addEventListener('visibilitychange',function(){
          if(document.visibilityState==='hidden'){
            bgEnteredAt=Date.now();
            if(!pendingReply)lastBaselineTail=captureLatestChatSnippet();
            ensureBackgroundObserver();
          }else{
            ensureBackgroundObserver();
          }
        });
        })();
        """#
        return WKUserScript(
            source: js,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
    }

    /// SPA-safe page-level JS retention cleanup invoked right before WebKit/JSC memory pressure GC.
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
            forMainFrameOnly: true,
            in: .page
        )
    }
}
