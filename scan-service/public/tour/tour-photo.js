(function () {
  'use strict';

  function render(viewport, room, photoIndex, opts) {
    var options = opts || {};
    var photos = Array.isArray(room.photos) ? room.photos : [];
    if (photos.length === 0) {
      renderEmpty(viewport, options.onBackToPlan);
      return;
    }
    var idx = photoIndex;
    if (idx < 0 || idx >= photos.length) {
      idx = 0;
    }

    var stage = document.createElement('div');
    stage.className = 'tour-photo-stage';

    var url = photos[idx].url;
    var img = document.createElement('img');
    img.className = 'tour-photo-image';
    img.alt = room.label || 'Tour photo';
    img.src = options.buildPhotoUrl ? options.buildPhotoUrl(url) : url;
    stage.appendChild(img);

    stage.appendChild(circleButton('tour-photo-close', '\u00D7', window.TourStrings.t('close_photo'), options.onClose));

    if (photos.length > 1) {
      stage.appendChild(circleButton('tour-photo-prev', '\u2039', window.TourStrings.t('prev_photo'), options.onPrev));
      stage.appendChild(circleButton('tour-photo-next', '\u203A', window.TourStrings.t('next_photo'), options.onNext));
    }

    viewport.appendChild(stage);
  }

  function renderEmpty(viewport, onBackToPlan) {
    var wrap = document.createElement('div');
    wrap.className = 'tour-empty-block';

    var p = document.createElement('p');
    p.textContent = window.TourStrings.t('no_photos');
    wrap.appendChild(p);

    var back = document.createElement('button');
    back.type = 'button';
    back.className = 'tour-btn tour-btn-primary';
    back.textContent = window.TourStrings.t('back_to_plan');
    back.addEventListener('click', onBackToPlan);
    wrap.appendChild(back);

    viewport.appendChild(wrap);
  }

  function circleButton(className, glyph, ariaLabel, onClick) {
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'tour-circle ' + className;
    btn.textContent = glyph;
    btn.setAttribute('aria-label', ariaLabel);
    btn.addEventListener('click', onClick);
    return btn;
  }

  window.TourPhoto = { render: render };
})();
