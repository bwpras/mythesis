function corrected = correct_time_spacing(subset, desired_dt)
    t_original = subset.Time;
    p_original = subset.Pressure_filter;
    g_original = subset.Gradient;

    if numel(t_original) < 2 || (t_original(end) - t_original(1)) < seconds(desired_dt)
        corrected = subset;
        return;
    end

    t_new = t_original(1):seconds(desired_dt):t_original(end);

    if numel(t_new) < 2
        corrected = subset;
        return;
    end

    p_new = interp1(t_original, p_original, t_new, 'linear');
    g_new = interp1(t_original, g_original, t_new, 'linear');

    corrected = struct( ...
        'Time', t_new(:), ...
        'Pressure_filter', p_new(:), ...
        'Gradient', g_new(:));
end
