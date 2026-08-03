function Test_out = runFiltering(data, Fs, fc, windowSize, windowGrad)
    dt = 1/Fs;
    filterOrder = 1;
    [b,a] = butter(filterOrder, fc/(Fs/2));
    numTests = numel(data);
    Test_out = data;

    for j = 1:numTests
        N = length(data(j).Time);
        Test_out(j).Pressure_mean_filter = zeros(N,1);
        Test_out(j).Pressure_filter = zeros(N,1);
        Test_out(j).Gradient_pressure = zeros(N,1);

        movingSum = 0;
        movingSum_grad = 0;
        buffer = zeros(windowSize,1);
        buffer_grad = zeros(windowGrad,1);
        bufferIndex = 1;
        bufferIndex_grad = 1;

        for c1 = 1:N
            newVal = data(j).Pressure(c1);
            movingSum = movingSum - buffer(bufferIndex) + newVal;
            buffer(bufferIndex) = newVal;
            bufferIndex = mod(bufferIndex, windowSize) + 1;
            Test_out(j).Pressure_mean_filter(c1) = movingSum / min(c1, windowSize);

            if c1 == 1
                Test_out(j).Pressure_filter(c1) = b(1)*Test_out(j).Pressure_mean_filter(c1);
            else
                Test_out(j).Pressure_filter(c1) = b(1)*Test_out(j).Pressure_mean_filter(c1) + ...
                                                  b(2)*Test_out(j).Pressure_mean_filter(c1-1) - ...
                                                  a(2)*Test_out(j).Pressure_filter(c1-1);
            end

            if c1 > 1
                Test_out(j).Gradient_pressure(c1) = ...
                    (Test_out(j).Pressure_filter(c1) - Test_out(j).Pressure_filter(c1-1))/dt;
            end

            newVal_grad = Test_out(j).Gradient_pressure(c1);
            movingSum_grad = movingSum_grad - buffer_grad(bufferIndex_grad) + newVal_grad;
            buffer_grad(bufferIndex_grad) = newVal_grad;
            bufferIndex_grad = mod(bufferIndex_grad, windowGrad) + 1;
            Test_out(j).Gradient_pressure_filtered(c1) = movingSum_grad / min(c1, windowGrad);
        end
    end
end