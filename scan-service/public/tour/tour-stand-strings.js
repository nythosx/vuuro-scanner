(function () {
  'use strict';

  var STRINGS = {
    en: {
      toggle_photos: 'Photos',
      toggle_walkthrough: 'Walk-through',
      arrow_label: 'Go to the next stand',
      stand_heading_label: 'Look around',
      stand_gap_label: 'No photo for this direction',
      stand_single_fallback: 'Only one photo at this stand',
      transition_prefers_reduced: 'Reduced motion: instant change',
      embed_tab_tour: 'Tour',
      embed_tab_dollhouse: 'Dollhouse',
      embed_tab_plan: 'Plan',
      hint_stand: 'Drag to look around. Tap a circle on the floor to walk there.',
      turn_left_label: 'Turn left towards the next spot',
      turn_right_label: 'Turn right towards the next spot',
      strip_aria: 'Spots in this home',
      loading_spot: 'Loading this spot\u2026',
      fullscreen_label: 'Full screen',
      tour_play_label: 'Start guided tour',
      tour_stop_label: 'Stop guided tour',
      measure_label: 'Measure: click two points'
    },
    nl: {
      toggle_photos: 'Foto\u2019s',
      toggle_walkthrough: 'Rondleiding',
      arrow_label: 'Ga naar het volgende punt',
      stand_heading_label: 'Kijk rond',
      stand_gap_label: 'Geen foto in deze richting',
      stand_single_fallback: 'Slechts \u00e9\u00e9n foto op dit punt',
      transition_prefers_reduced: 'Minder beweging: directe wissel',
      embed_tab_tour: 'Rondleiding',
      embed_tab_dollhouse: 'Poppenhuis',
      embed_tab_plan: 'Plattegrond',
      hint_stand: 'Sleep om rond te kijken. Tik op een cirkel op de vloer om erheen te lopen.',
      turn_left_label: 'Draai naar links, naar het volgende punt',
      turn_right_label: 'Draai naar rechts, naar het volgende punt',
      strip_aria: 'Punten in deze woning',
      loading_spot: 'Dit punt wordt geladen\u2026',
      fullscreen_label: 'Volledig scherm',
      tour_play_label: 'Start rondleiding',
      tour_stop_label: 'Stop rondleiding',
      measure_label: 'Meten: klik op twee punten'
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
