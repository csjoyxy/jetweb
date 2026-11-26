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
}
