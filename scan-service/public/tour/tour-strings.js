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
      plan_photo_cluster: '{count} photos',
      plan_stand_spot: '360 spot {number}',
      plan_floors_aria: 'Floors',
      plan_floor_other: 'Other',
      dollhouse_unavailable: 'Dollhouse not available for this scan.',
      loading_3d: 'Loading 3D view\u2026',
      dollhouse_load_failed: 'Could not load the dollhouse: {reason}.',
      webgl_unavailable: 'WebGL is not available in this browser',
      prev_room_aria: 'Previous room',
      next_room_aria: 'Next room',
      tour_mode_aria: 'Tour view mode',
      popout_full_tour: 'Open full tour',
      hint_plan: 'Tap a room to open its photos.',
      hint_photos: 'Use the arrows to see the next photo. Tap \u00D7 to go back to the plan.',
      hint_dollhouse: 'Drag to rotate, pinch or scroll to zoom, drag with two fingers or right-click to move. Tap a dot to open its photo.',
      hint_model: 'Drag to rotate, pinch or scroll to zoom, drag with two fingers or right-click to move. Double-tap a spot to turn around it.',
      menu_model: '3D scan',
      model_mode_photo: 'Photo',
      model_mode_clay: 'Clay',
      model_mode_mesh: 'Mesh',
      model_ceiling: 'Ceiling',
      model_reset_view: 'Reset view',
      model_unavailable: 'No 3D scan has been sent for this tour yet.',
      model_load_failed: 'Could not load the 3D scan: {reason}.',
      model_loading_percent: 'Loading 3D scan\u2026 {percent}%',
      model_triangles: '{count} triangles',
      model_photo_one: '{count} photo',
      model_photos: '{count} photos'
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
      menu_dollhouse: 'Poppenhuis',
      no_photos: 'Nog geen tourfoto\u2019s voor deze ruimte.',
      back_to_plan: 'Terug naar plattegrond',
      close_photo: 'Sluit fotoweergave',
      prev_photo: 'Vorige foto',
      next_photo: 'Volgende foto',
      plan_aria: 'Plattegrond',
      minimap_aria: 'Plattegrond-minikaart',
      plan_photo_cluster: '{count} foto\u2019s',
      plan_stand_spot: '360\u00b0-plek {number}',
      plan_floors_aria: 'Verdiepingen',
      plan_floor_other: 'Overig',
      dollhouse_unavailable: 'Poppenhuis niet beschikbaar voor deze scan.',
      loading_3d: '3D-weergave laden\u2026',
      dollhouse_load_failed: 'Kon het poppenhuis niet laden: {reason}.',
      webgl_unavailable: 'WebGL is niet beschikbaar in deze browser',
      prev_room_aria: 'Vorige ruimte',
      next_room_aria: 'Volgende ruimte',
      tour_mode_aria: 'Rondleiding weergavemodus',
      popout_full_tour: 'Open volledige rondleiding',
      hint_plan: 'Tik op een ruimte om de foto\u2019s te openen.',
      hint_photos: 'Gebruik de pijlen voor de volgende foto. Tik op \u00D7 om terug te gaan naar de plattegrond.',
      hint_dollhouse: 'Sleep om te draaien, knijp of scroll om te zoomen, sleep met twee vingers of rechtsklik om te verschuiven. Tik op een punt om de foto te openen.',
      hint_model: 'Sleep om te draaien, knijp of scroll om te zoomen, sleep met twee vingers of rechtsklik om te verschuiven. Dubbeltik op een plek om eromheen te draaien.',
      menu_model: '3D-scan',
      model_mode_photo: 'Foto',
      model_mode_clay: 'Klei',
      model_mode_mesh: 'Mesh',
      model_ceiling: 'Plafond',
      model_reset_view: 'Beeld herstellen',
      model_unavailable: 'Voor deze rondleiding is nog geen 3D-scan verstuurd.',
      model_load_failed: 'Kon de 3D-scan niet laden: {reason}.',
      model_loading_percent: '3D-scan laden\u2026 {percent}%',
      model_triangles: '{count} driehoeken',
      model_photo_one: '{count} foto',
      model_photos: '{count} foto\u2019s'
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
