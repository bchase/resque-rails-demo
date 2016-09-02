$ ->
  $('.export td:first()').each (i, td) ->
    if $(td).text() == 'building'
      id   = $(td).closest('tr').data('id')
      func = ->
        $.getJSON "/exports/#{id}", (data) ->
          location.reload() if data.complete

      setInterval func, 1000
