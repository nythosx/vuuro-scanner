(function () {
  'use strict';

  var STRINGS = {
    en: {
      loading_tour: 'Loading tour\u2026',
      invalid_url: 'Invalid tour URL \u2014 no session id.',
      missing_token: 'Missing token in the URL. Add ?token=\u2026 to the link.',
      link_expired: 'This link is no longer valid.',
      server_http: 'Server returned HTTP {status}.',
      load_failed: 'Could not load the tour.',
      no_rooms: 'No rooms have been captured yet.',
      menu_plan: 'Plan',
      menu_photos: 'Photo tour',
      menu_dollhouse: 'Dollhouse',
      no_photos: 'No tour photos for this room yet.',
      back_to_plan: 'Back to plan',
      close_photo: 'Close photo tour',
      prev_photo: 'Previous photo',
      next_photo: 'Next photo',
      plan_aria: 'Floor plan',
      minimap_aria: 'Floor plan minimap',
      dollhouse_unavailable: 'Dollhouse not available for this scan.',
      loading_3d: 'Loading 3D view\u2026',
      dollhouse_load_failed: 'Could not load the dollhouse: {reason}.',
      webgl_unavailable: 'WebGL is not available in this browser',
      prev_room_aria: 'Previous room',
      next_room_aria: 'Next room',
      tour_mode_aria: 'Tour view mode',
      popout_full_tour: 'Open full tour'
    },
    nl: {
      loading_tour: 'Rondleiding laden\u2026',
      invalid_url: 'Ongeldige rondleidings-URL \u2014 geen sessie-id.',
      missing_token: 'Token ontbreekt in de URL. Voeg ?token=\u2026 toe aan de link.',
      link_expired: 'Deze link is niet meer geldig.',
      server_http: 'Server gaf HTTP {status} terug.',
      load_failed: 'Kon de rondleiding niet laden.',
      no_rooms: 'Er zijn nog geen ruimtes vastgelegd.',
      menu_plan: 'Plattegrond',
      menu_photos: 'Foto\u2019s',
      menu_dollhouse: 'Dollhouse',
      no_photos: 'Nog geen tourfoto\u2019s voor deze ruimte.',
      back_to_plan: 'Terug naar plattegrond',
      close_photo: 'Sluit fotoweergave',
      prev_photo: 'Vorige foto',
      next_photo: 'Volgende foto',
      plan_aria: 'Plattegrond',
      minimap_aria: 'Plattegrond-minikaart',
      dollhouse_unavailable: 'Dollhouse niet beschikbaar voor deze scan.',
      loading_3d: '3D-weergave laden\u2026',
      dollhouse_load_failed: 'Kon het dollhouse niet laden: {reason}.',
      webgl_unavailable: 'WebGL is niet beschikbaar in deze browser',
      prev_room_aria: 'Vorige ruimte',
      next_room_aria: 'Volgende ruimte',
      tour_mode_aria: 'Rondleiding weergavemodus',
      popout_full_tour: 'Open volledige rondleiding'
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

  window.TourStrings = { t: t, lang: lang };
})();
