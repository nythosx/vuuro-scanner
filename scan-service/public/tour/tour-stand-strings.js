(function () {
  'use strict';

  var STRINGS = {
    en: {
      toggle_group_aria: 'Photo view mode',
      toggle_photos: 'Photos',
      toggle_walkthrough: 'Walk-through',
      arrow_label: 'Go to the next stand',
      minimap_stand_aria: 'Current stand highlighted',
      stand_heading_label: 'Look around',
      stand_gap_label: 'No photo for this direction',
      stand_single_fallback: 'Only one photo at this stand',
      transition_prefers_reduced: 'Reduced motion: instant change',
      embed_tab_tour: 'Tour',
      embed_tab_dollhouse: 'Dollhouse',
      embed_tab_plan: 'Plan'
    },
    nl: {
      toggle_group_aria: 'Weergave foto\u2019s',
      toggle_photos: 'Foto\u2019s',
      toggle_walkthrough: 'Rondleiding',
      arrow_label: 'Ga naar het volgende punt',
      minimap_stand_aria: 'Huidige positie gemarkeerd',
      stand_heading_label: 'Kijk rond',
      stand_gap_label: 'Geen foto in deze richting',
      stand_single_fallback: 'Slechts \u00e9\u00e9n foto op dit punt',
      transition_prefers_reduced: 'Minder beweging: directe wissel',
      embed_tab_tour: 'Rondleiding',
      embed_tab_dollhouse: 'Poppenhuis',
      embed_tab_plan: 'Plattegrond'
    }
  };

  function resolveLang() {
    var attr = document.body ? document.body.getAttribute('data-tour-lang') : null;
    if (attr === 'en' || attr === 'nl') {
      return attr;
    }
    var nav = (navigator.language || '').toLowerCase();
    if (nav.indexOf('nl') === 0) {
      return 'nl';
    }
    return 'en';
  }

  var lang = resolveLang();

  function t(key, vars) {
    var table = STRINGS[lang] || STRINGS.en;
    var text = table[key];
    if (typeof text !== 'string') {
      text = STRINGS.en[key];
    }
    if (typeof text !== 'string') {
      return key;
    }
    if (vars) {
      Object.keys(vars).forEach(function (k) {
        text = text.split('{' + k + '}').join(String(vars[k]));
      });
    }
    return text;
  }

  window.TourStandStrings = { t: t, lang: lang };
})();
