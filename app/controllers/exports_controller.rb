class ExportsController < ApplicationController
  before_action :set_export, only: [:show, :edit, :update, :destroy]

  # GET /exports
  # GET /exports.json
  def index
    @exports = Export.all
  end

  # GET /exports/1
  # GET /exports/1.json
  def show
  end

  # GET /exports/new
  def new
    @export = Export.new
  end

  # GET /exports/1/edit
  def edit
  end

  # POST /exports
  # POST /exports.json
  def create
    @export = Export.new(export_params)

    respond_to do |format|
      if @export.save
        @export.async_populate!

        format.html { redirect_to exports_path, notice: 'Your export is being created, please wait.' }
        format.json { render :show, status: :created, location: @export }
      else
        format.html { render :new }
        format.json { render json: @export.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /exports/1
  # PATCH/PUT /exports/1.json
  def update
    respond_to do |format|
      if @export.update(export_params)
        format.html { redirect_to @export, notice: 'Export was successfully updated.' }
        format.json { render :show, status: :ok, location: @export }
      else
        format.html { render :edit }
        format.json { render json: @export.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /exports/1
  # DELETE /exports/1.json
  def destroy
    @export.destroy
    respond_to do |format|
      format.html { redirect_to exports_url, notice: 'Export was successfully destroyed.' }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_export
      @export = Export.find(params[:id])
    end

    # Never trust parameters from the scary internet, only allow the white list through.
    def export_params
      {} # params.require(:export).permit(:complete)
    end
end
