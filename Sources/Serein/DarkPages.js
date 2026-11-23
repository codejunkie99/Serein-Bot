(() => {
  if (globalThis.__sereinDarkPages) return;
  globalThis.__sereinDarkPages = enabled => {
    document.getElementById('serein-dark-page')?.remove();
    if (!enabled) return;
    const style=document.createElement('style');style.id='serein-dark-page';
    const brightness=css=>{const a=css.match(/[\d.]+/g)?.map(Number);return !a||a.length<3||(a.length===4&&a[3]===0)?null:(a[0]*.2126+a[1]*.7152+a[2]*.0722)};
    const body=document.body?brightness(getComputedStyle(document.body).backgroundColor):null;
    const root=brightness(getComputedStyle(document.documentElement).backgroundColor);
    // A page with no background of its own shows the canvas: dark only if the page says it has a
    // dark scheme, white otherwise. Counting it as dark put dark text on a dark canvas.
    const scheme=getComputedStyle(document.documentElement).colorScheme+' '+(document.querySelector('meta[name="color-scheme"]')?.content??'');
    const canvas=/dark/.test(scheme)?0:255;
    // Respect sites with an existing dark palette; adapt light backgrounds only.
    style.textContent=(body??root??canvas)>170
      ? 'html{filter:invert(.91) hue-rotate(180deg)!important;background:#eee!important}img,video,picture,canvas,svg image{filter:invert(1) hue-rotate(180deg)!important}'
      : ':root{color-scheme:dark}';
    document.documentElement.append(style);
  };
})();
